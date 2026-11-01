Vim_Range :: struct {
    #as using range: Offset_Range;
    linewise: bool;
}

vim_native :: (editor: *Editor, buffer: *Buffer, action: Action_Editors) {
    if !active_editor_handle_event(editor, buffer, Input.Event.{}, action) then handle_common_editor_action(action);
}

vim_sync_buffer :: (editor: *Editor, buffer: *Buffer) {
    if !buffer.dirty return;
    rescan_for_lines(buffer);
    if line_wrap_is_active(editor) then rescan_for_wrapped_lines(editor, buffer);
}

vim_begin_change :: (editor: *Editor, buffer: *Buffer) {
    new_edit_group(buffer, editor);
    remember_cursors_before_first_edit(buffer, editor);
    vim_mark_change();
    maybe_make_temporary_editor_permanent();
}

vim_end_change :: (editor: *Editor, buffer: *Buffer) {
    vim_sync_buffer(editor, buffer);
    organise_cursors(editor);
    if vim.mode != .insert then new_edit_group(buffer, editor);
    if vim.mode == .normal then vim_clamp_cursors(editor, buffer);
    buffer.last_edit_time = frame_time64;
    editor.cursor_moved = true;
    editor.refresh_selection = true;
    cursors_start_blinking();
}

vim_edit_group :: (editor: *Editor, buffer: *Buffer) #expand {
    if buffer.readonly `return;
    vim_begin_change(editor, buffer);
    `defer vim_end_change(editor, buffer);
}

vim_cursors :: (editor: *Editor, body: Code, flags: For_Flags) #expand {
    cursors_buffer := *open_buffers[editor.buffer_id];
    delta: s32 = 0;

    for cursor_index : 0 .. editor.cursors.count - 1 {
        length_before := cursors_buffer.bytes.count;

        `it := *editor.cursors[cursor_index];
        `it_index := cursor_index;
        `offset_delta := delta;

        it.pos += delta;
        it.sel += delta;

        #insert body;

        delta += cast(s32) (cursors_buffer.bytes.count - length_before);
    }
}

vim_begin_operator :: (editor: *Editor, buffer: *Buffer, op: Vim_Operator, key: u32) {
    if vim_is_visual(vim.mode) {
        ranges := vim_visual_ranges(editor);
        vim_release_visual();
        vim_apply_operator(editor, buffer, op, ranges);
        return;
    }

    if vim.mode != .normal return;
    if vim_operator_writes(op) && buffer.readonly return;

    vim.op = op;
    vim.operator_key = key;
    vim.operator_count = vim.count;
    vim.count = 0;
    vim_set_mode(.operator_pending);
}

vim_operate_with_motion :: (editor: *Editor, buffer: *Buffer, op: Vim_Operator, motion: Vim_Motion, char: u32, count: s32) {
    ranges: [..] Vim_Range;
    ranges.allocator = temp;

    for * cursor : editor.cursors {
        range, found := vim_range_from_motion(buffer, cursor, op, motion, char, count);
        if !found {
            vim_set_mode(.normal);
            return;
        }
        array_add(*ranges, range);
    }

    vim_apply_operator(editor, buffer, op, ranges);
}

vim_operate_on_current_lines :: (editor: *Editor, buffer: *Buffer, op: Vim_Operator, count: s32) {
    ranges: [..] Vim_Range;
    ranges.allocator = temp;

    for cursor : editor.cursors {
        first := offset_to_real_line(buffer, cursor.pos);
        last  := min(first + count - 1, get_max_real_line_num(buffer));
        array_add(*ranges, Vim_Range.{
            range    = .{ get_real_line_start_offset(buffer, first), vim_line_end_with_newline(buffer, last) },
            linewise = true,
        });
    }

    vim_apply_operator(editor, buffer, op, ranges);
}

vim_apply_operator :: (editor: *Editor, buffer: *Buffer, op: Vim_Operator, ranges: [] Vim_Range) {
    vim_set_mode(.normal);
    if vim_operator_writes(op) && buffer.readonly return;

    if op == .delete || op == .delete_no_yank || op == .change {
        for * range, range_index : ranges {
            if range_index == 0 continue;
            range.start = max(range.start, ranges[range_index - 1].end);
            range.end   = max(range.end, range.start);
        }
    }

    if #complete op == {
        case .none;

        case .yank;
            vim_yank_ranges(buffer, ranges);
            for * cursor, cursor_index : editor.cursors {
                range := ranges[cursor_index];
                same_line := offset_to_real_line(buffer, cursor.pos) == offset_to_real_line(buffer, range.start);
                if !range.linewise {
                    cursor.pos = range.start;
                } else if !same_line {
                    cursor.pos = vim_first_nonblank(buffer, offset_to_real_line(buffer, range.start));
                }
                cursor.sel = cursor.pos;
            }
            vim_clamp_cursors(editor, buffer);
            editor.cursor_moved = true;

        case .delete;         vim_delete_ranges(editor, buffer, ranges, yank = true);
        case .delete_no_yank; vim_delete_ranges(editor, buffer, ranges, yank = false);
        case .change;         vim_change_ranges(editor, buffer, ranges);

        case .indent;         vim_native_on_lines(editor, buffer, ranges, .indent);
        case .unindent;       vim_native_on_lines(editor, buffer, ranges, .unindent);
        case .autoindent;     vim_native_on_lines(editor, buffer, ranges, .autoindent_region);
        case .comment;        vim_native_on_lines(editor, buffer, ranges, .toggle_comment);

        case .lowercase;      vim_change_case(editor, buffer, ranges, .lowercase);
        case .uppercase;      vim_change_case(editor, buffer, ranges, .uppercase);
        case .toggle_case;    vim_change_case(editor, buffer, ranges, .toggle_case);
    }
}

vim_visual_ranges :: (editor: *Editor) -> [] Vim_Range {
    ranges: [..] Vim_Range;
    ranges.allocator = temp;
    for cursor : editor.cursors {
        array_add(*ranges, Vim_Range.{ range = get_selection(cursor), linewise = vim.mode == .visual_line });
    }
    return ranges;
}

vim_replace_chars :: (editor: *Editor, buffer: *Buffer, char: u32, count: s32) {
    vim_edit_group(editor, buffer);

    utf8_char := convert_utf32_to_utf8(char);
    replacement := to_string(*utf8_char);
    repeated := vim_repeat_string(replacement, count);

    for :vim_cursors editor {
        line_end := get_real_line_end_offset(buffer, offset_to_real_line(buffer, it.pos));

        end := it.pos;
        available := 0;
        while available < count && end < line_end {
            end = next_char_offset(buffer.bytes, end);
            available += 1;
        }

        if available == count {
            replace_range(buffer, .{ it.pos, end }, repeated);
            vim_sync_buffer(editor, buffer);
            it.pos += cast(s32) (replacement.count * (count - 1));
            it.sel = it.pos;
        }
    }
}

vim_paste :: (editor: *Editor, buffer: *Buffer, after: bool, count: s32) {
    if buffer.readonly return;

    text, linewise := vim_read_register();
    if !text return;

    vim_edit_group(editor, buffer);

    repeated := vim_repeat_string(text, count);

    for :vim_cursors editor {
        line := offset_to_real_line(buffer, it.pos);

        if linewise {
            at: s32;
            content := repeated;
            prepended_newline := after && is_last_real_line(buffer, line);
            if prepended_newline {
                at = cast(s32) buffer.bytes.count;
                content = tprint("\n%", slice(repeated, 0, repeated.count - 1));
            } else {
                at = ifx after then get_real_line_start_offset(buffer, line + 1) else get_real_line_start_offset(buffer, line);
            }
            insert_string_at_offset(buffer, at, content);
            vim_sync_buffer(editor, buffer);
            first_new := offset_to_real_line(buffer, ifx prepended_newline then at + 1 else at);
            it.pos = vim_first_nonblank(buffer, first_new);
        } else {
            line_end := get_real_line_end_offset(buffer, line);
            at := it.pos;
            if after && at < line_end then at = next_char_offset(buffer.bytes, at);
            insert_string_at_offset(buffer, at, repeated);
            vim_sync_buffer(editor, buffer);
            it.pos = prev_char_offset(buffer.bytes, at + cast(s32) repeated.count);
        }
        it.sel = it.pos;
        it.col_wanted = -1;
    }
}

vim_paste_over_selection :: (editor: *Editor, buffer: *Buffer, count: s32, keep_register: bool) {
    if buffer.readonly return;

    text, text_is_linewise := vim_read_register();
    if !text return;

    ranges := vim_visual_ranges(editor);
    if !keep_register then vim_yank_ranges(buffer, ranges);

    vim_release_visual();
    vim_set_mode(.normal);

    vim_edit_group(editor, buffer);

    repeated := vim_repeat_string(text, count);

    for :vim_cursors editor {
        range := ranges[it_index];
        start := range.start + offset_delta;
        end   := range.end   + offset_delta;

        content := repeated;
        if range.linewise && !text_is_linewise && end > start && buffer.bytes[end - 1] == #char "\n" {
            content = tprint("%\n", repeated);
        }
        if !range.linewise && text_is_linewise {
            content = slice(repeated, 0, repeated.count - 1);
        }

        replace_range(buffer, .{ start, end }, content);
        vim_sync_buffer(editor, buffer);

        it.pos = ifx text_is_linewise || range.linewise then start else prev_char_offset(buffer.bytes, start + cast(s32) content.count);
        it.sel = it.pos;
    }
}

vim_open_line :: (editor: *Editor, buffer: *Buffer, below: bool) {
    vim_edit_group(editor, buffer);

    for :vim_cursors editor {
        line   := offset_to_real_line(buffer, it.pos);
        start  := get_real_line_start_offset(buffer, line);
        first  := vim_first_nonblank(buffer, line);
        indent := get_range_as_string(buffer, .{ start, first });
        if vim_open_line_goes_deeper(buffer, line, first, below) {
            type, size := get_buffer_indentation_and_tab_size(buffer);
            indent = tprint("%1%2", indent, ifx type == .tabs then "\t" else get_tmp_spaces(size));
        }

        if below {
            at := get_real_line_end_offset(buffer, line);
            insert_string_at_offset(buffer, at, tprint("\n%", indent));
            it.pos = at + 1 + cast(s32) indent.count;
        } else {
            insert_string_at_offset(buffer, start, tprint("%\n", indent));
            it.pos = start + cast(s32) indent.count;
        }
        it.sel = it.pos;
        vim_sync_buffer(editor, buffer);
    }

    vim_set_mode(.insert);
}

vim_open_line_goes_deeper :: (buffer: *Buffer, line: s32, first: s32, below: bool) -> bool {
    end := get_real_line_end_offset(buffer, line);
    if first >= end return false;

    bytes := buffer.bytes;
    if !below {
        return bytes[first] == #char "}" || bytes[first] == #char ")" || bytes[first] == #char "]";
    }

    last := end - 1;
    while last > first && is_space(bytes[last]) last -= 1;
    return bytes[last] == #char "{" || bytes[last] == #char "(" || bytes[last] == #char "[";
}

vim_enter_insert :: (editor: *Editor, buffer: *Buffer, where: enum { before; after; line_start; line_end; }) {
    if buffer.readonly return;
    new_edit_group(buffer, editor);

    for * cursor : editor.cursors {
        line := offset_to_real_line(buffer, cursor.pos);
        if where == {
            case .after;
                if cursor.pos < get_real_line_end_offset(buffer, line) then cursor.pos = next_char_offset(buffer.bytes, cursor.pos);
            case .line_start;
                cursor.pos = vim_first_nonblank(buffer, line);
            case .line_end;
                cursor.pos = get_real_line_end_offset(buffer, line);
        }
        cursor.sel = cursor.pos;
    }
    editor.cursor_moved = true;
    vim_set_mode(.insert);
}

vim_join_lines :: (editor: *Editor, buffer: *Buffer, count: s32) {
    vim_edit_group(editor, buffer);

    for :vim_cursors editor {
        original_pos := it.pos;
        line := offset_to_real_line(buffer, it.pos);

        for 1 .. max(count - 1, 1) {
            if is_last_real_line(buffer, line) break;

            line_end   := get_real_line_end_offset(buffer, line);
            next_first := vim_first_nonblank(buffer, line + 1);
            next_end   := get_real_line_end_offset(buffer, line + 1);

            needs_space := next_first < next_end && buffer.bytes[next_first] != #char ")";
            replace_range(buffer, .{ line_end, next_first }, ifx needs_space then " " else "");
            vim_sync_buffer(editor, buffer);
        }

        it.pos = original_pos;
        it.sel = original_pos;
    }
}

vim_undo :: (editor: *Editor, buffer: *Buffer, is_redo: bool, count: s32) {
    for 1 .. count {
        new_edit_group(buffer, editor);

        stack := ifx is_redo then *buffer.redos else *buffer.undos;
        if !stack.count break;

        group := peek(stack.*);
        target := ifx is_redo then group.cursors_before else group.cursors_after;
        restore_cursor_state(editor, target);
        editor.original_cursor = clamp(editor.original_cursor, 0, cast(s32) target.count - 1);

        vim_native(editor, buffer, ifx is_redo then Action_Editors.redo else .undo);
        vim_sync_buffer(editor, buffer);
    }

    for * cursor : editor.cursors {
        cursor.pos = min(cursor.pos, cursor.sel);
        cursor.sel = cursor.pos;
        cursor.col_wanted = -1;
    }
    vim_clamp_cursors(editor, buffer);
    editor.cursor_moved = true;
}

vim_move_selected_lines :: (editor: *Editor, buffer: *Buffer, down: bool) {
    vim_edit_group(editor, buffer);

    for :vim_cursors editor {
        visual := *vim.visual_cursors[it_index];
        first := offset_to_real_line(buffer, min(visual.anchor, visual.head));
        last  := offset_to_real_line(buffer, max(visual.anchor, visual.head));

        can_move := ifx down then !is_last_real_line(buffer, last) else first > 0;
        if can_move {
            block_start := get_real_line_start_offset(buffer, first);
            block_end   := get_real_line_end_offset(buffer, last);
            block := copy_temporary_string(get_range_as_string(buffer, .{ block_start, block_end }));

            moved: s32;
            if down {
                other_end := get_real_line_end_offset(buffer, last + 1);
                other := copy_temporary_string(get_range_as_string(buffer, .{ block_end + 1, other_end }));
                replace_range(buffer, .{ block_start, other_end }, tprint("%\n%", other, block));
                moved = cast(s32) other.count + 1;
            } else {
                other_start := get_real_line_start_offset(buffer, first - 1);
                other := copy_temporary_string(get_range_as_string(buffer, .{ other_start, block_start - 1 }));
                replace_range(buffer, .{ other_start, block_end }, tprint("%\n%", block, other));
                moved = -(cast(s32) other.count + 1);
            }
            visual.anchor += moved;
            visual.head   += moved;
            vim_sync_buffer(editor, buffer);
        }
    }

    vim_visual_apply(editor, buffer);
}

vim_run_action :: (editor: *Editor, buffer: *Buffer, action: Vim_Action, key: u32) {
    count := vim_effective_count();

    if #complete action == {
        case .escape;
            had_pending := vim.count > 0 || vim.op != .none;
            if vim.mode == .normal && !had_pending {
                vim_native(editor, buffer, .escape);
            } else if vim.mode != .normal {
                vim_set_mode(.normal);
            }

        case .current_line;
            if key == vim.operator_key {
                vim_operate_on_current_lines(editor, buffer, vim.op, count);
            } else {
                vim_cancel_pending();
            }

        case .insert_before;      vim_enter_insert(editor, buffer, .before);
        case .insert_after;       vim_enter_insert(editor, buffer, .after);
        case .insert_line_start;  vim_enter_insert(editor, buffer, .line_start);
        case .insert_line_end;    vim_enter_insert(editor, buffer, .line_end);
        case .open_below;         vim_open_line(editor, buffer, below = true);
        case .open_above;         vim_open_line(editor, buffer, below = false);

        case .enter_visual;
            vim_set_mode(ifx vim.mode == .visual then Vim_Mode.normal else .visual);

        case .enter_visual_line;
            vim_set_mode(ifx vim.mode == .visual_line then Vim_Mode.normal else .visual_line);

        case .swap_visual_ends;
            for * visual : vim.visual_cursors {
                visual.anchor, visual.head = visual.head, visual.anchor;
            }
            vim_visual_apply(editor, buffer);

        case .move_lines_down;    vim_move_selected_lines(editor, buffer, down = true);
        case .move_lines_up;      vim_move_selected_lines(editor, buffer, down = false);

        case .delete_char;        vim_operate_with_motion(editor, buffer, .delete, .right, 0, count);
        case .delete_char_before; vim_operate_with_motion(editor, buffer, .delete, .left, 0, count);
        case .delete_to_line_end; vim_operate_with_motion(editor, buffer, .delete, .line_end, 0, count);
        case .change_to_line_end; vim_operate_with_motion(editor, buffer, .change, .line_end, 0, count);
        case .yank_to_line_end;   vim_operate_with_motion(editor, buffer, .yank, .line_end, 0, count);
        case .substitute_char;    vim_operate_with_motion(editor, buffer, .change, .right, 0, count);
        case .substitute_line;    vim_operate_on_current_lines(editor, buffer, .change, count);

        case .replace_char;
            if !buffer.readonly {
                vim.awaiting = .replace_char;
            }

        case .toggle_case_char;
            vim_operate_with_motion(editor, buffer, .toggle_case, .right, 0, count);
            vim_run_motion(editor, buffer, .right, 0);

        case .join_lines;         vim_join_lines(editor, buffer, count);

        case .paste_after;
            if vim_is_visual(vim.mode) vim_paste_over_selection(editor, buffer, count, keep_register = false);
            else vim_paste(editor, buffer, after = true, count);

        case .paste_before;
            if vim_is_visual(vim.mode) vim_paste_over_selection(editor, buffer, count, keep_register = true);
            else vim_paste(editor, buffer, after = false, count);

        case .paste_no_yank;      vim_paste_over_selection(editor, buffer, count, keep_register = true);

        case .undo;               vim_undo(editor, buffer, is_redo = false, count);
        case .redo;               vim_undo(editor, buffer, is_redo = true,  count);
        case .repeat_change;      vim_repeat_last_change(count);

        case .open_ex;            vim_open_ex_line(editor, buffer);
        case .search_forward;     vim_open_search_line(editor, forward = true);
        case .search_backward;    vim_open_search_line(editor, forward = false);
        case .search_word_forward;  vim_search_word(editor, buffer, forward = true,  count);
        case .search_word_backward; vim_search_word(editor, buffer, forward = false, count);
        case .substitute_word;    vim_open_substitute_word(editor, buffer);

        case .center_view;        editor.scroll_to_cursor = .center;
        case .view_cursor_top;    editor.scroll_to_cursor = .top;
        case .view_cursor_bottom; editor.scroll_to_cursor = .bottom;
        case .jump_back;          vim_native(editor, buffer, .cursor_go_back);
        case .jump_forward;       vim_native(editor, buffer, .cursor_go_forward);
        case .next_comment;       vim_jump_to_comment(editor, buffer, forward = true);
        case .previous_comment;   vim_jump_to_comment(editor, buffer, forward = false);

        case .add_cursor_below;   vim_native(editor, buffer, .create_cursor_below);

        case .cursors_from_selected_lines;
            vim_release_visual();
            vim_native(editor, buffer, .add_cursors_to_line_starts);
            for * cursor : editor.cursors  cursor.sel = cursor.pos;
            vim_set_mode(.normal);

        case .cursors_on_all_occurrences;
            vim_native(editor, buffer, .select_all_occurrences);

        case .remove_additional_cursors;
            if vim_is_visual(vim.mode) then vim_set_mode(.normal);
            vim_native(editor, buffer, .remove_additional_cursors);

        case .find_file;          handle_common_editor_action(.open_file_by_name);
        case .search_project;     handle_common_editor_action(.search_in_project);

        case .search_project_for_word;
            vim_native(editor, buffer, .select_word);
            handle_common_editor_action(.search_in_project);
            for * cursor : editor.cursors  cursor.sel = cursor.pos;

        case .switch_open_files;  handle_common_editor_action(.switch_between_open_files);
        case .browse_directory;   handle_common_editor_action(.navigate_to_file);

        case .build;              vim_run_build(0);
        case .rebuild;            vim_run_build(vim.last_build_command);

        case .toggle_build_panel; handle_common_editor_action(.toggle_build_panel);
        case .kill_build;         handle_common_editor_action(.build_kill_running_command);
        case .next_build_error;   handle_common_editor_action(.go_to_next_build_error);
        case .previous_build_error; handle_common_editor_action(.go_to_previous_build_error);

        case .cycle_panes;        vim_cycle_panes();
        case .alternate_buffer;   vim_alternate_buffer();
    }
}


#scope_file

vim_operator_writes :: (op: Vim_Operator) -> bool {
    return op != .yank && op != .none;
}

vim_range_from_motion :: (buffer: *Buffer, cursor: *Cursor, op: Vim_Operator, motion: Vim_Motion, char: u32, count: s32) -> Vim_Range, found: bool {
    from := cursor.pos;

    effective_motion := motion;
    is_word_motion := motion == .word_forward || motion == .big_word_forward;
    if is_word_motion && op == .change && from < buffer.bytes.count && !vim_is_space_at(buffer, from) {
        effective_motion = ifx motion == .big_word_forward then Vim_Motion.big_word_end else .word_end;
    }

    motion_from := ifx effective_motion == motion then from else from - 1;
    target := vim_compute_motion(buffer, cursor, effective_motion, motion_from, count, char);
    if !target.found return .{}, false;

    if effective_motion == .word_forward || effective_motion == .big_word_forward {
        from_line   := offset_to_real_line(buffer, from);
        target_line := offset_to_real_line(buffer, target.offset);
        if target_line > from_line then target.offset = get_real_line_end_offset(buffer, target_line - 1);
    }

    low  := min(from, target.offset);
    high := max(from, target.offset);

    result: Vim_Range;
    if #complete target.kind == {
        case .exclusive;
            result.range = .{ low, high };

        case .inclusive;
            steps_past_high := high < buffer.bytes.count && buffer.bytes[high] != #char "\n";
            result.range = .{ low, ifx steps_past_high then next_char_offset(buffer.bytes, high) else high };

        case .linewise;
            result.range = .{
                get_real_line_start_offset(buffer, offset_to_real_line(buffer, low)),
                vim_line_end_with_newline(buffer, offset_to_real_line(buffer, high)),
            };
            result.linewise = true;
    }
    return result, true;
}

vim_yank_ranges :: (buffer: *Buffer, ranges: [] Vim_Range) {
    builder: String_Builder;
    builder.allocator = temp;

    any_linewise := false;
    for range, range_index : ranges {
        text := get_range_as_string(buffer, range);
        append(*builder, text);
        if range.linewise {
            any_linewise = true;
            if !text || text[text.count - 1] != #char "\n" then append(*builder, "\n");
        } else if range_index < ranges.count - 1 {
            append(*builder, "\n");
        }
    }

    combined := builder_to_string(*builder,, allocator = temp);
    if !combined return;

    if vim.register_text then free(vim.register_text);
    vim.register_text = copy_string(combined);
    vim.register_linewise = any_linewise;
    os_clipboard_set_text(vim.register_text);
}

vim_read_register :: () -> text: string, linewise: bool {
    system_text := os_clipboard_get_text();
    defer free(system_text);

    bytes := to_bytes(system_text);
    remove_crlf_in_place(*bytes);
    text := copy_temporary_string(cast(string) bytes);
    if !text return "", false;

    linewise := ifx text == vim.register_text then vim.register_linewise else text[text.count - 1] == #char "\n";
    if linewise && text[text.count - 1] != #char "\n" then text = tprint("%\n", text);
    return text, linewise;
}

vim_repeat_string :: (text: string, count: s32) -> string {
    builder: String_Builder;
    builder.allocator = temp;
    for 1 .. max(count, 1)  append(*builder, text);
    return builder_to_string(*builder,, allocator = temp);
}

vim_delete_ranges :: (editor: *Editor, buffer: *Buffer, ranges: [] Vim_Range, yank: bool) {
    if yank then vim_yank_ranges(buffer, ranges);

    vim_edit_group(editor, buffer);

    for :vim_cursors editor {
        range := ranges[it_index];
        start := range.start + offset_delta;
        end   := range.end   + offset_delta;

        if start < end {
            if range.linewise && end >= buffer.bytes.count && start > 0 && buffer.bytes[end - 1] != #char "\n" then start -= 1;
            delete_range(buffer, .{ start, end });
        }

        it.pos = min(start, cast(s32) buffer.bytes.count);
        if range.linewise {
            vim_sync_buffer(editor, buffer);
            if it.pos > 0 && it.pos == buffer.bytes.count && buffer.bytes[it.pos - 1] == #char "\n" then it.pos -= 1;
            it.pos = vim_first_nonblank(buffer, offset_to_real_line(buffer, it.pos));
        }
        it.sel = it.pos;
        it.col_wanted = -1;
    }
}

vim_change_ranges :: (editor: *Editor, buffer: *Buffer, ranges: [] Vim_Range) {
    vim_yank_ranges(buffer, ranges);

    vim_edit_group(editor, buffer);

    for :vim_cursors editor {
        range := ranges[it_index];
        start := range.start + offset_delta;
        end   := range.end   + offset_delta;

        if start < end {
            if range.linewise {
                start = vim_first_nonblank(buffer, offset_to_real_line(buffer, start));
                end   = get_real_line_end_offset(buffer, offset_to_real_line(buffer, max(end - 1, start)));
                end   = max(end, start);
            }

            delete_range(buffer, .{ start, end });
            if range.linewise then vim_sync_buffer(editor, buffer);
        }

        it.pos = start;
        it.sel = start;
    }

    vim_set_mode(.insert);
}

vim_native_on_lines :: (editor: *Editor, buffer: *Buffer, ranges: [] Vim_Range, action: Action_Editors) {
    vim_edit_group(editor, buffer);

    for * cursor, cursor_index : editor.cursors {
        range := ranges[cursor_index];
        first := offset_to_real_line(buffer, range.start);
        last  := offset_to_real_line(buffer, max(range.end - 1, range.start));
        cursor.sel = get_real_line_start_offset(buffer, first);
        cursor.pos = get_real_line_end_offset(buffer, last);
    }

    vim_native(editor, buffer, action);
    vim_sync_buffer(editor, buffer);

    for * cursor : editor.cursors {
        start := min(cursor.pos, cursor.sel);
        cursor.pos = vim_first_nonblank(buffer, offset_to_real_line(buffer, start));
        cursor.sel = cursor.pos;
    }
}

vim_change_case :: (editor: *Editor, buffer: *Buffer, ranges: [] Vim_Range, op: Vim_Operator) {
    vim_edit_group(editor, buffer);

    for * cursor, cursor_index : editor.cursors {
        range := ranges[cursor_index];
        text := copy_temporary_string(get_range_as_string(buffer, range));

        for * byte : cast([] u8) text {
            if op == {
                case .lowercase;   byte.* = to_lower(byte.*);
                case .uppercase;   byte.* = to_upper(byte.*);
                case .toggle_case; byte.* = ifx is_upper(byte.*) then to_lower(byte.*) else to_upper(byte.*);
            }
        }

        replace_range(buffer, range, text);
        cursor.pos = range.start;
        cursor.sel = range.start;
    }
}

vim_search_word :: (editor: *Editor, buffer: *Buffer, forward: bool, count: s32) {
    main := editor.cursors[editor.main_cursor];

    probe := main;
    select_word(buffer, *probe);
    needle := copy_temporary_string(get_selected_string(probe, buffer));
    if !needle return;

    vim_set_last_search(needle, forward, whole_word = true);
    vim_search_update(editor, buffer, needle, true);
    vim_search_jump(editor, get_selection(probe).start, forward, count);
}

vim_jump_to_comment :: (editor: *Editor, buffer: *Buffer, forward: bool) {
    if vim_is_visual(vim.mode) {
        for * visual : vim.visual_cursors {
            offset, found := vim_next_comment_line(buffer, visual.head, forward);
            if found then visual.head = offset;
        }
        vim_visual_apply(editor, buffer);
        return;
    }

    for * cursor : editor.cursors {
        offset, found := vim_next_comment_line(buffer, cursor.pos, forward);
        if found {
            cursor.pos = offset;
            cursor.sel = offset;
            cursor.col_wanted = -1;
        }
    }
    organise_cursors(editor);
    editor.cursor_moved = true;
}

vim_run_build :: (command_id: s64) {
    commands := context.config.build.commands.count;
    if !commands {
        add_user_warning("No build commands are configured", dismiss_in_seconds = 5);
        return;
    }
    maybe_execute_a_build_command(cast(Action_Build) ifx command_id < commands then command_id else 0);
}

vim_cycle_panes :: () {
    leaves := gather_leaf_pane_rects();
    if leaves.count < 2 return;

    for leaves {
        if it.pane == editors.active_pane {
            activate_pane(leaves[(it_index + 1) % leaves.count].pane);
            return;
        }
    }
}

vim_alternate_buffer :: () {
    if most_recent_buffers.count < 2 return;
    editors_open_buffer(most_recent_buffers[1], .in_place);
}
