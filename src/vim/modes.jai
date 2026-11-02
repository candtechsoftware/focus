Vim_Mode :: enum u8 {
    normal;
    insert;
    visual;
    visual_line;
    operator_pending;
    command;
}

vim_mode_label :: (mode: Vim_Mode) -> string {
    if #complete mode == {
        case .normal;           return "NORMAL";
        case .insert;           return "INSERT";
        case .visual;           return "VISUAL";
        case .visual_line;      return "V-LINE";
        case .operator_pending; return "NORMAL";
        case .command;          return "COMMAND";
    }
}

Vim_Awaiting :: enum u8 {
    none;
    motion_char;
    replace_char;
}

Vim_Pending :: struct {
    count:          s32;
    operator_count: s32;
    op:             Vim_Operator;
    operator_key:   u32;
    awaiting:       Vim_Awaiting;
    awaiting_motion: Vim_Motion;
    keys:           [VIM_MAX_KEYS] u32;
    key_count:      s32;
}

Vim_Visual_Cursor :: struct {
    anchor: s32;
    head:   s32;
}

vim: struct {
    mode := Vim_Mode.normal;

    using pending: Vim_Pending;

    editor_id: s64 = -1;
    visual_cursors: [..] Vim_Visual_Cursor;

    current_record: [..] u32;
    last_change:    [..] u32;
    change_pending: bool;
    replaying:      bool;

    last_find_motion: Vim_Motion;
    last_find_char:   u32;

    last_search:       string;
    search_forward:    bool = true;
    search_whole_word: bool;

    register_text:     string;
    register_linewise: bool;

    last_build_command: s64;
};

VIM_SCROLLOFF :: 2;

vim_enabled :: inline () -> bool {
    return context.config.settings.vim_mode;
}

vim_widget_has_focus :: inline () -> bool {
    return active_global_widget == .editors || active_global_widget == .build_panel;
}

vim_holds_undo_group :: inline () -> bool {
    return vim_enabled() && vim.mode == .insert;
}

vim_status_label :: () -> string {
    label := vim_mode_label(vim.mode);

    pending_text: String_Builder;
    pending_text.allocator = temp;
    if vim.operator_count > 0 print_to_builder(*pending_text, "%", vim.operator_count);
    if vim.op != .none  print_to_builder(*pending_text, "%", vim.op);
    if vim.count > 0          print_to_builder(*pending_text, " %", vim.count);
    for 0 .. vim.key_count - 1 {
        key := vim.keys[it];
        if key < VIM_KEY_BASE {
            utf8_key := convert_utf32_to_utf8(key);
            print_to_builder(*pending_text, "%", to_string(*utf8_key));
        }
    }

    pending := builder_to_string(*pending_text,, allocator = temp);
    if pending return tprint("%  %", label, pending);
    return label;
}

vim_set_mode :: (to: Vim_Mode) {
    from := vim.mode;
    if from == to return;

    vim_exit_mode(from, to);
    vim.mode = to;
    vim_enter_mode(to);

    cursors_start_blinking();
    redraw_requested = true;
}

vim_reset_pending :: () {
    vim.pending = .{};
}

vim_release_visual :: () {
    array_reset_keeping_memory(*vim.visual_cursors);
}

vim_is_visual :: inline (mode: Vim_Mode) -> bool {
    return mode == .visual || mode == .visual_line;
}

vim_visual_range_for_cursor :: (buffer: Buffer, visual: Vim_Visual_Cursor, mode: Vim_Mode) -> pos: s32, sel: s32 {
    forward := visual.head >= visual.anchor;

    start, end: s32;
    if mode == .visual_line {
        first := offset_to_real_line(buffer, min(visual.head, visual.anchor));
        last  := offset_to_real_line(buffer, max(visual.head, visual.anchor));
        start = get_real_line_start_offset(buffer, first);
        end   = vim_line_end_with_newline(buffer, last);
    } else {
        start = min(visual.head, visual.anchor);
        high := max(visual.head, visual.anchor);
        end = ifx high < buffer.bytes.count then next_char_offset(buffer.bytes, high) else high;
    }

    if forward return end, start;
    return start, end;
}

vim_visual_apply :: (editor: *Editor, buffer: *Buffer) {
    if vim.visual_cursors.count != editor.cursors.count return;
    for * cursor, cursor_index : editor.cursors {
        cursor.pos, cursor.sel = vim_visual_range_for_cursor(buffer, vim.visual_cursors[cursor_index], vim.mode);
    }
    editor.cursor_moved = true;
    editor.refresh_selection = true;
}

vim_visual_load_from_selection :: (editor: *Editor, buffer: *Buffer) {
    array_reset_keeping_memory(*vim.visual_cursors);
    for cursor : editor.cursors {
        visual: Vim_Visual_Cursor;
        if cursor.pos > cursor.sel {
            visual.anchor = cursor.sel;
            visual.head   = prev_char_offset(buffer.bytes, cursor.pos);
        } else if cursor.pos < cursor.sel {
            visual.anchor = prev_char_offset(buffer.bytes, cursor.sel);
            visual.head   = cursor.pos;
        } else {
            visual.anchor = cursor.pos;
            visual.head   = cursor.pos;
        }
        array_add(*vim.visual_cursors, visual);
    }
}

vim_cursor_draw_offset :: (editor_id: s64, cursor: Cursor, cursor_index: int) -> s32 {
    if vim_enabled() && vim_widget_has_focus() && editor_id == vim.editor_id && vim_is_visual(vim.mode) && cursor_index < vim.visual_cursors.count {
        return vim.visual_cursors[cursor_index].head;
    }
    return cursor.pos;
}

vim_clamp_cursors :: (editor: *Editor, buffer: *Buffer) {
    for * cursor : editor.cursors {
        clamped := vim_clamp_offset(buffer, cursor.pos);
        if clamped != cursor.pos {
            cursor.pos = clamped;
            cursor.sel = clamped;
            editor.cursor_moved = true;
            redraw_requested = true;
        }
    }
}

vim_reconcile :: () {
    if !vim_enabled() {
        vim.mode = .normal;
        vim_reset_pending();
        vim_release_visual();
        return;
    }

    if vim.mode == .command {
        if active_global_widget != .vim_command_line then vim_set_mode(.normal);
        return;
    }

    if !vim_widget_has_focus() return;

    editor_id := get_active_editor_id();
    if editor_id < 0 return;
    editor, buffer := get_editor_and_buffer(editor_id);

    if vim.editor_id != editor_id {
        vim.editor_id = editor_id;
        if vim.mode != .insert {
            vim_release_visual();
            vim_reset_pending();
            vim_set_mode(.normal);
        }
    }

    if editor.search_bar.active return;

    if #complete vim.mode == {
        case .normal;
            if !vim_adopt_selection(editor, buffer) then vim_clamp_cursors(editor, buffer);

        case .insert;
            if buffer.readonly {
                vim.change_pending = false;
                vim_set_mode(.normal);
            }

        case .visual;      #through;
        case .visual_line;
            if !vim_visual_matches_selection(editor, buffer) {
                if !vim_adopt_selection(editor, buffer) {
                    vim_release_visual();
                    vim_set_mode(.normal);
                }
                redraw_requested = true;
            }

        case .operator_pending;
        case .command;
    }
}

vim_adopt_selection :: (editor: *Editor, buffer: *Buffer) -> adopted: bool {
    for editor.cursors {
        if has_selection(it) {
            array_reset_keeping_memory(*vim.current_record);
            vim_visual_load_from_selection(editor, buffer);
            vim_set_mode(.visual);
            return true;
        }
    }
    return false;
}

vim_swallows_keyboard_event :: (event: Input.Event) -> bool {
    if !vim_enabled() || vim.mode == .insert || vim.mode == .command return false;
    if !vim_widget_has_focus() return false;
    if event.type != .KEYBOARD || !event.key_pressed return false;

    editor := get_active_editor_and_buffer();
    if !editor || editor.search_bar.active return false;

    return vim_is_text_key(event);
}

vim_handle_event :: (event: Input.Event) -> intercepted: bool, handled: bool {
    if !vim_enabled() return false, false;

    is_key_press := event.type == .KEYBOARD && event.key_pressed;
    if !is_key_press && event.type != .TEXT_INPUT return false, false;

    editor := get_active_editor_and_buffer();
    if !editor || editor.search_bar.active return false, false;

    vim_reconcile();

    if event.type == {
        case .KEYBOARD;
            key := vim_key_from_event(event);

            if vim.mode == .insert {
                if key == VIM_KEY_ESC || (key == VIM_KEY_ENTER && event.shift_pressed) {
                    vim_handle_key(key);
                    return true, true;
                }
                if vim_key_is_editing(key) && !(key == VIM_KEY_TAB && event.shift_pressed) {
                    array_add(*vim.current_record, key);
                }
                return false, false;
            }

            if key != VIM_KEY_NONE {
                if key == VIM_KEY_ENTER && build_panel_is_active() return false, false;
                if vim_handle_key(key) return true, true;

                if vim_key_is_editing(key) return true, true;
                return false, false;
            }

            if vim_is_text_key(event) return true, false;
            return false, false;

        case .TEXT_INPUT;
            if vim.mode == .insert {
                array_add(*vim.current_record, event.utf32);
                return false, false;
            }
            vim_handle_key(event.utf32);
            return true, true;
    }

    return false, false;
}

vim_handle_key :: (key: u32) -> bound: bool {
    editor, buffer := get_active_editor_and_buffer();
    if !editor return false;

    previous_editor_id := context.current_editor_id;
    context.current_editor_id = get_active_editor_id();
    defer context.current_editor_id = previous_editor_id;

    if !vim.replaying {
        at_command_start := vim.mode == .normal && vim.key_count == 0 && vim.count == 0 && vim.awaiting == .none;
        if at_command_start then array_reset_keeping_memory(*vim.current_record);
        array_add(*vim.current_record, key);
    }
    defer vim_finish_command();

    if vim.mode == .insert {
        vim_handle_insert_key(key);
        return true;
    }

    if vim.awaiting != .none {
        vim_handle_awaited_char(editor, buffer, key);
        return true;
    }

    is_digit := key >= #char "0" && key <= #char "9";
    if is_digit && vim.key_count == 0 && (key != #char "0" || vim.count > 0) {
        vim.count = cast(s32) min(cast(s64) vim.count * 10 + (key - #char "0"), VIM_MAX_COUNT);
        return true;
    }

    vim.keys[vim.key_count] = key;
    vim.key_count += 1;

    keys: [] u32;
    keys.data  = vim.keys.data;
    keys.count = vim.key_count;

    lookup, binding := vim_lookup_binding(keys, vim_mode_flag(vim.mode));
    if lookup == {
        case .none;
            retry_as_new_command := vim.key_count > 1 && vim.mode != .operator_pending;
            vim_cancel_pending();
            if !retry_as_new_command return false;
            if !vim.replaying then array_reset_keeping_memory(*vim.current_record);
            return vim_handle_key(key);

        case .partial;
            return true;

        case .exact;
            vim_run_binding(editor, buffer, binding, key);
            return true;
    }

    return false;
}

vim_cancel_pending :: () {
    vim_reset_pending();
    if vim.mode == .operator_pending then vim_set_mode(.normal);
}

VIM_MAX_COUNT :: 99999;

vim_key_is_editing :: inline (key: u32) -> bool {
    return key == VIM_KEY_ENTER || key == VIM_KEY_BACKSPACE || key == VIM_KEY_DELETE || key == VIM_KEY_TAB;
}

vim_record_replacement :: (prefix: string, word: string) {
    for 1 .. num_chars_in_string(prefix)  array_add(*vim.current_record, VIM_KEY_BACKSPACE);

    remaining := word;
    while remaining {
        char, result := utf8_next_character(*remaining);
        if result != .CONVERSION_OK break;
        array_add(*vim.current_record, char);
    }
}

vim_has_count :: inline () -> bool {
    return vim.count > 0 || vim.operator_count > 0;
}

vim_effective_count :: inline () -> s32 {
    return max(vim.count, 1) * max(vim.operator_count, 1);
}

vim_run_binding :: (editor: *Editor, buffer: *Buffer, binding: Vim_Binding, key: u32) {
    defer if vim.mode != .operator_pending && vim.awaiting == .none then vim_reset_pending();

    vim.key_count = 0;

    if #complete binding.kind == {
        case .motion;       vim_begin_motion(editor, buffer, cast(Vim_Motion) binding.code);
        case .text_object;  vim_run_text_object(editor, buffer, cast(Vim_Text_Object) binding.code, around = binding.keys[0] == #char "a");
        case .op;     vim_begin_operator(editor, buffer, cast(Vim_Operator) binding.code, key);
        case .action;       vim_run_action(editor, buffer, cast(Vim_Action) binding.code, key);
    }
}

vim_mark_change :: inline () {
    vim.change_pending = true;
}

vim_finish_command :: () {
    if vim.replaying return;
    if vim.mode == .insert || vim.mode == .operator_pending || vim_is_visual(vim.mode) return;
    if vim.key_count > 0 || vim.count > 0 || vim.awaiting != .none return;

    if vim.change_pending {
        vim.change_pending = false;
        array_reset_keeping_memory(*vim.last_change);
        array_add(*vim.last_change, ..vim.current_record);
    }
}

vim_repeat_last_change :: (repetitions: s32) {
    if !vim.last_change return;

    keys := array_copy(vim.last_change,, temp);
    vim_reset_pending();

    vim.replaying = true;
    defer {
        vim.replaying = false;
        vim.change_pending = false;
        vim_cancel_pending();
    }

    for 1 .. repetitions {
        for key : keys vim_handle_key(key);
    }
}


#scope_file

vim_mode_flag :: (mode: Vim_Mode) -> Vim_Modes {
    if #complete mode == {
        case .normal;           return .normal;
        case .visual;           return .visual;
        case .visual_line;      return .visual_line;
        case .operator_pending; return .operator_pending;
        case .insert;           return 0;
        case .command;          return 0;
    }
}

vim_exit_mode :: (from: Vim_Mode, to: Vim_Mode) {
    if #complete from == {
        case .normal;
        case .operator_pending;

        case .insert;
            editor, buffer := get_active_editor_and_buffer();
            if editor {
                vim_sync_buffer(editor, buffer);
                for * cursor : editor.cursors {
                    line_start := get_real_line_start_offset(buffer, offset_to_real_line(buffer, cursor.pos));
                    if cursor.pos > line_start then cursor.pos = prev_char_offset(buffer.bytes, cursor.pos);
                    cursor.sel = cursor.pos;
                }
                new_edit_group(buffer, editor);
                editor.cursor_moved = true;
            }

        case .visual;      #through;
        case .visual_line;
            if !vim_is_visual(to) {
                editor := get_active_editor_and_buffer();
                if editor && vim.visual_cursors.count == editor.cursors.count {
                    for * cursor, cursor_index : editor.cursors {
                        cursor.pos = vim.visual_cursors[cursor_index].head;
                        cursor.sel = cursor.pos;
                    }
                    editor.cursor_moved = true;
                    editor.refresh_selection = true;
                }
                vim_release_visual();
            }

        case .command;
            if active_global_widget == .vim_command_line then activate_editors();
    }
}

vim_enter_mode :: (to: Vim_Mode) {
    if #complete to == {
        case .normal;
            editor, buffer := get_active_editor_and_buffer();
            if editor {
                vim_clamp_cursors(editor, buffer);
                for * cursor : editor.cursors  cursor.col_wanted = -1;
            }

        case .insert;
            vim_mark_change();
            editor := get_active_editor_and_buffer();
            if editor {
                for * cursor : editor.cursors  cursor.col_wanted = -1;
            }

        case .visual;      #through;
        case .visual_line;
            editor, buffer := get_active_editor_and_buffer();
            if !editor return;
            if !vim.visual_cursors {
                for cursor : editor.cursors {
                    array_add(*vim.visual_cursors, Vim_Visual_Cursor.{ anchor = cursor.pos, head = cursor.pos });
                }
            }
            vim_visual_apply(editor, buffer);

        case .operator_pending;

        case .command;
            active_global_widget = .vim_command_line;
    }
}

vim_visual_matches_selection :: (editor: *Editor, buffer: *Buffer) -> bool {
    if vim.visual_cursors.count != editor.cursors.count return false;
    for cursor, cursor_index : editor.cursors {
        pos, sel := vim_visual_range_for_cursor(buffer, vim.visual_cursors[cursor_index], vim.mode);
        if pos != cursor.pos || sel != cursor.sel return false;
    }
    return true;
}

vim_is_text_key :: (event: Input.Event) -> bool {
    if event.text_input_count == 0 || event.ctrl_pressed || event.cmd_meta_pressed || event.alt_pressed return false;

    code := cast(u32) event.key_code;
    return event.key_code == .UNKNOWN || (code >= #char " " && code < cast(u32) Input.Key_Code.DELETE);
}

vim_key_from_event :: (event: Input.Event) -> u32 {
    if event.cmd_meta_pressed || event.alt_pressed return VIM_KEY_NONE;

    code := cast(u32) event.key_code;

    if event.ctrl_pressed {
        if event.shift_pressed return VIM_KEY_NONE;
        if code == #char "["   return VIM_KEY_ESC;
        if code >= #char "A" && code <= #char "Z" return vim_ctrl_key(code + 32);
        if code >= #char "a" && code <= #char "z" return vim_ctrl_key(code);
        if code == #char "," || code == #char "." return vim_ctrl_key(code);
        return VIM_KEY_NONE;
    }

    if event.key_code == {
        case .ESCAPE;    return VIM_KEY_ESC;
        case .ENTER;     return VIM_KEY_ENTER;
        case .BACKSPACE; return VIM_KEY_BACKSPACE;
        case .DELETE;    return VIM_KEY_DELETE;
        case .TAB;       return VIM_KEY_TAB;
    }

    if event.shift_pressed return VIM_KEY_NONE;

    if event.key_code == {
        case .ARROW_UP;    return VIM_KEY_UP;
        case .ARROW_DOWN;  return VIM_KEY_DOWN;
        case .ARROW_LEFT;  return VIM_KEY_LEFT;
        case .ARROW_RIGHT; return VIM_KEY_RIGHT;
        case .HOME;        return VIM_KEY_HOME;
        case .END;         return VIM_KEY_END;
        case .PAGE_UP;     return VIM_KEY_PAGE_UP;
        case .PAGE_DOWN;   return VIM_KEY_PAGE_DOWN;
    }

    return VIM_KEY_NONE;
}

vim_handle_insert_key :: (key: u32) {
    if key == VIM_KEY_ESC {
        vim_set_mode(.normal);
        return;
    }

    editor, buffer := get_active_editor_and_buffer();
    if key == {
        case VIM_KEY_ENTER;     vim_native(editor, buffer, .break_line);
        case VIM_KEY_BACKSPACE; vim_native(editor, buffer, .delete_left_char);
        case VIM_KEY_DELETE;    vim_native(editor, buffer, .delete_right_char);
        case VIM_KEY_TAB;       vim_native(editor, buffer, .indent_or_go_to_next_tabstop);
        case;
            if key < VIM_KEY_BASE then active_editor_type_char(key);
    }
}

vim_handle_awaited_char :: (editor: *Editor, buffer: *Buffer, key: u32) {
    awaiting := vim.awaiting;
    motion   := vim.awaiting_motion;
    vim.awaiting = .none;

    defer if vim.mode != .operator_pending && vim.awaiting == .none then vim_reset_pending();

    if key >= VIM_KEY_BASE {
        vim_cancel_pending();
        return;
    }

    if #complete awaiting == {
        case .none;
        case .motion_char;  vim_run_motion(editor, buffer, motion, key);
        case .replace_char; vim_replace_chars(editor, buffer, key, vim_effective_count());
    }
}
