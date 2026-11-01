Vim_Motion_Kind :: enum u8 {
    exclusive;
    inclusive;
    linewise;
}

Vim_Target :: struct {
    offset: s32;
    kind:   Vim_Motion_Kind;
    found:  bool;
}

vim_line_end_with_newline :: (buffer: Buffer, line: s32) -> s32 {
    if is_last_real_line(buffer, line) return cast(s32) buffer.bytes.count;
    return get_real_line_start_offset(buffer, line + 1);
}

vim_first_nonblank :: (buffer: Buffer, line: s32) -> s32 {
    start := get_real_line_start_offset(buffer, line);
    return start + count_whitespace(buffer.bytes, start, get_real_line_end_offset(buffer, line));
}

vim_clamp_offset :: (buffer: Buffer, offset: s32) -> s32 {
    offset = clamp(offset, 0, cast(s32) buffer.bytes.count);
    if offset < buffer.bytes.count && buffer.bytes[offset] != #char "\n" return offset;

    line  := offset_to_real_line(buffer, offset);
    start := get_real_line_start_offset(buffer, line);
    end   := get_real_line_end_offset(buffer, line);
    if end > start && offset >= end return prev_char_offset(buffer.bytes, end);
    return offset;
}

vim_compute_motion :: (buffer: *Buffer, cursor: *Cursor, motion: Vim_Motion, from: s32, count: s32, char: u32) -> Vim_Target {
    target := Vim_Target.{ offset = from, kind = .exclusive, found = true };
    vertical_delta: s32 = 0;

    if #complete motion == {
        case .left;
            line_start := get_real_line_start_offset(buffer, offset_to_real_line(buffer, from));
            for 1 .. count {
                if target.offset <= line_start break;
                target.offset = prev_char_offset(buffer.bytes, target.offset);
            }

        case .right;
            line_end := get_real_line_end_offset(buffer, offset_to_real_line(buffer, from));
            for 1 .. count {
                if target.offset >= line_end break;
                target.offset = next_char_offset(buffer.bytes, target.offset);
            }

        case .down;
            vertical_delta = count;

        case .up;
            vertical_delta = -count;

        case .next_line_start;
            line := min(offset_to_real_line(buffer, from) + count, get_max_real_line_num(buffer));
            target.offset = vim_first_nonblank(buffer, line);
            target.kind = .linewise;

        case .word_forward;       for 1 .. count  target.offset = vim_word_forward(buffer, target.offset, big = false);
        case .big_word_forward;   for 1 .. count  target.offset = vim_word_forward(buffer, target.offset, big = true);
        case .word_backward;      for 1 .. count  target.offset = vim_word_backward(buffer, target.offset, big = false);
        case .big_word_backward;  for 1 .. count  target.offset = vim_word_backward(buffer, target.offset, big = true);

        case .word_end;
            for 1 .. count  target.offset = vim_word_end(buffer, target.offset, big = false);
            target.kind = .inclusive;

        case .big_word_end;
            for 1 .. count  target.offset = vim_word_end(buffer, target.offset, big = true);
            target.kind = .inclusive;

        case .line_start;
            target.offset = get_real_line_start_offset(buffer, offset_to_real_line(buffer, from));

        case .first_nonblank;
            target.offset = vim_first_nonblank(buffer, offset_to_real_line(buffer, from));

        case .line_end;
            line := min(offset_to_real_line(buffer, from) + count - 1, get_max_real_line_num(buffer));
            target.offset = vim_clamp_offset(buffer, get_real_line_end_offset(buffer, line));
            target.kind = .inclusive;

        case .file_start;
            line := ifx vim_has_count() then count - 1 else 0;
            target.offset = vim_first_nonblank(buffer, min(line, get_max_real_line_num(buffer)));
            target.kind = .linewise;

        case .file_end;
            line := ifx vim_has_count() then count - 1 else get_max_real_line_num(buffer);
            target.offset = vim_first_nonblank(buffer, min(line, get_max_real_line_num(buffer)));
            target.kind = .linewise;

        case .paragraph_forward;
            for 1 .. count  target.offset = vim_paragraph_forward(buffer, target.offset);

        case .paragraph_backward;
            for 1 .. count  target.offset = vim_paragraph_backward(buffer, target.offset);

        case .matching_bracket;
            target.offset, target.found = vim_matching_bracket(buffer, from);
            target.kind = .inclusive;

        case .find_forward;  #through;
        case .find_backward; #through;
        case .till_forward;  #through;
        case .till_backward;
            target = vim_find_char_target(buffer, from, motion, char, count, repeating = false);

        case .repeat_find;
            if !vim.last_find_char then target.found = false;
            else target = vim_find_char_target(buffer, from, vim.last_find_motion, vim.last_find_char, count, repeating = true);

        case .repeat_find_reversed;
            if !vim.last_find_char then target.found = false;
            else target = vim_find_char_target(buffer, from, vim_reversed_find(vim.last_find_motion), vim.last_find_char, count, repeating = true);

        case .half_page_down;
            vertical_delta = count * vim_half_page_lines();

        case .half_page_up;
            vertical_delta = -count * vim_half_page_lines();

        case .page_down;
            vertical_delta = count * 2 * vim_half_page_lines();

        case .page_up;
            vertical_delta = -count * 2 * vim_half_page_lines();

        case .search_next;
            target.offset, target.found = vim_search_target(from, vim.search_forward, count);

        case .search_previous;
            target.offset, target.found = vim_search_target(from, !vim.search_forward, count);
    }

    if vertical_delta {
        target.offset = vim_vertical_target(buffer, cursor, from, vertical_delta);
        target.kind = .linewise;
    } else {
        cursor.col_wanted = cast(s32) (ifx motion == .line_end then S32_MAX else -1);
    }

    return target;
}

vim_motion_awaits_char :: (motion: Vim_Motion) -> bool {
    return motion == .find_forward || motion == .find_backward || motion == .till_forward || motion == .till_backward;
}

vim_motion_centers_view :: (motion: Vim_Motion) -> bool {
    return motion == .half_page_down || motion == .half_page_up || motion == .search_next || motion == .search_previous;
}

vim_begin_motion :: (editor: *Editor, buffer: *Buffer, motion: Vim_Motion) {
    if vim_motion_awaits_char(motion) {
        vim.awaiting = .motion_char;
        vim.awaiting_motion = motion;
        return;
    }

    if motion == .search_next || motion == .search_previous then vim_search_prepare(editor, buffer);

    vim_run_motion(editor, buffer, motion, 0);
}

vim_run_motion :: (editor: *Editor, buffer: *Buffer, motion: Vim_Motion, char: u32) {
    if vim_motion_awaits_char(motion) {
        vim.last_find_motion = motion;
        vim.last_find_char = char;
    }

    count     := vim_effective_count();

    if #complete vim.mode == {
        case .normal;
            for * cursor : editor.cursors {
                target := vim_compute_motion(buffer, cursor, motion, cursor.pos, count, char);
                if target.found {
                    cursor.pos = target.offset;
                    cursor.sel = target.offset;
                }
            }
            organise_cursors(editor);
            vim_clamp_cursors(editor, buffer);

        case .visual;      #through;
        case .visual_line;
            for * cursor, cursor_index : editor.cursors {
                visual := *vim.visual_cursors[cursor_index];
                target := vim_compute_motion(buffer, cursor, motion, visual.head, count, char);
                if target.found then visual.head = target.offset;
            }
            vim_visual_apply(editor, buffer);

        case .operator_pending;
            vim_operate_with_motion(editor, buffer, vim.op, motion, char, count);

        case .insert;
        case .command;
    }

    editor.cursor_moved = true;
    editor.refresh_selection = true;
    if vim_motion_centers_view(motion) then editor.scroll_to_cursor = .yes;
}

vim_is_space_at :: inline (buffer: Buffer, offset: s32) -> bool {
    return vim_char_class(buffer.bytes[offset], false) == .space;
}

vim_text_object_range :: (buffer: *Buffer, object: Vim_Text_Object, around: bool, at: s32) -> Offset_Range, found: bool {
    range: Offset_Range;
    found: bool;

    if #complete object == {
        case .word;          range, found = vim_word_object(buffer, at, around);
        case .parens;        range, found = vim_pair_object(buffer, at, #char "(", #char ")", around);
        case .braces;        range, found = vim_pair_object(buffer, at, #char "{", #char "}", around);
        case .brackets;      range, found = vim_pair_object(buffer, at, #char "[", #char "]", around);
        case .double_quotes; range, found = vim_quote_object(buffer, at, #char "\"", around);
        case .single_quotes; range, found = vim_quote_object(buffer, at, #char "'", around);
        case .backticks;     range, found = vim_quote_object(buffer, at, #char "`", around);
    }

    return range, found;
}

vim_run_text_object :: (editor: *Editor, buffer: *Buffer, object: Vim_Text_Object, around: bool) {
    if vim_is_visual(vim.mode) {
        for * cursor, cursor_index : editor.cursors {
            visual := *vim.visual_cursors[cursor_index];
            range, found := vim_text_object_range(buffer, object, around, visual.head);
            if found && range.end > range.start {
                visual.anchor = range.start;
                visual.head   = prev_char_offset(buffer.bytes, range.end);
            }
        }
        vim_visual_apply(editor, buffer);
        return;
    }

    if vim.mode != .operator_pending return;

    ranges: [..] Vim_Range;
    ranges.allocator = temp;
    for cursor : editor.cursors {
        range, found := vim_text_object_range(buffer, object, around, cursor.pos);
        if !found {
            vim_set_mode(.normal);
            return;
        }
        array_add(*ranges, Vim_Range.{ range = range });
    }

    vim_apply_operator(editor, buffer, vim.op, ranges);
}

vim_search_prepare :: (editor: *Editor, buffer: *Buffer) {
    if !vim.last_search return;
    using editor.search_bar;
    if !results.count || to_string(input.text) != vim.last_search || whole_word != vim.search_whole_word {
        vim_search_update(editor, buffer, vim.last_search, vim.search_whole_word);
    }
}

vim_search_update :: (editor: *Editor, buffer: *Buffer, needle: string, whole_word: bool) {
    bar := *editor.search_bar;
    if to_string(bar.input.text) != needle then replace_text(*bar.input, needle);
    bar.whole_word = whole_word;
    bar.regex_search = false;
    bar.case_sensitive_toggled_manually = true;
    bar.case_sensitive = contains_uppercase_ascii(needle);
    search_and_update_results(editor, buffer);
    editor.refresh_selection = true;
}

vim_search_clear :: (editor: *Editor) {
    reset_search_results(*editor.search_bar);
    editor.refresh_selection = true;
}

vim_search_jump :: (editor: *Editor, from: s32, forward: bool, count: s32 = 1, skip_current := true) -> found: bool {
    offset, found := vim_search_target_in_bar(*editor.search_bar, from, forward, count, skip_current);
    if !found return false;

    cursor := leave_only_original_cursor(editor);
    cursor.pos = offset;
    cursor.sel = offset;
    cursor.col_wanted = -1;
    editor.cursor_moved = true;
    editor.scroll_to_cursor = .yes;
    return true;
}

vim_next_comment_line :: (buffer: Buffer, from: s32, forward: bool) -> s32, found: bool {
    line := offset_to_real_line(buffer, from);
    max_line := get_max_real_line_num(buffer);
    step: s32 = 1;
    if !forward then step = -1;

    line += step;
    while line >= 0 && line <= max_line {
        offset := vim_first_nonblank(buffer, line);
        if offset < buffer.tokens.count {
            type := buffer.tokens[offset];
            if type == .comment || type == .multiline_comment return offset, true;
        }
        line += step;
    }
    return from, false;
}


#scope_file

Vim_Char_Class :: enum u8 {
    space;
    word;
    punctuation;
}

vim_char_class :: inline (byte: u8, big: bool) -> Vim_Char_Class {
    if is_space(byte) return .space;
    if big || byte >= 0x80 || ascii_is_alnum(byte) return .word;
    return .punctuation;
}

vim_vertical_target :: (buffer: *Buffer, cursor: *Cursor, from: s32, delta: s32) -> s32 {
    line       := offset_to_real_line(buffer, from);
    line_start := get_real_line_start_offset(buffer, line);

    if cursor.col_wanted < 0 {
        column: s32 = 0;
        offset := line_start;
        while offset < from {
            offset = next_char_offset(buffer.bytes, offset);
            column += 1;
        }
        cursor.col_wanted = column;
    }

    target_line := clamp(line + delta, 0, get_max_real_line_num(buffer));
    offset := get_real_line_start_offset(buffer, target_line);
    end    := get_real_line_end_offset(buffer, target_line);
    for 1 .. cursor.col_wanted {
        if offset >= end break;
        offset = next_char_offset(buffer.bytes, offset);
    }
    return offset;
}

vim_half_page_lines :: () -> s32 {
    return max(cast(s32) (window_height / get_line_height()) / 2, 1);
}

vim_word_forward :: (buffer: *Buffer, from: s32, big: bool) -> s32 {
    bytes := buffer.bytes;
    count := cast(s32) bytes.count;
    offset := from;
    if offset >= count return count;

    class := vim_char_class(bytes[offset], big);
    if class != .space {
        while offset < count && vim_char_class(bytes[offset], big) == class offset += 1;
    }

    while offset < count && vim_char_class(bytes[offset], big) == .space {
        is_newline := bytes[offset] == #char "\n";
        offset += 1;
        if is_newline && offset < count && bytes[offset] == #char "\n" return offset;
    }
    return offset;
}

vim_word_end :: (buffer: *Buffer, from: s32, big: bool) -> s32 {
    bytes := buffer.bytes;
    count := cast(s32) bytes.count;
    if count == 0 return 0;

    offset := from + 1;
    while offset < count && vim_char_class(bytes[offset], big) == .space offset += 1;
    if offset >= count return count - 1;

    class := vim_char_class(bytes[offset], big);
    while offset + 1 < count && vim_char_class(bytes[offset + 1], big) == class offset += 1;
    while offset > 0 && (bytes[offset] & 0xC0) == 0x80 offset -= 1;
    return offset;
}

vim_word_backward :: (buffer: *Buffer, from: s32, big: bool) -> s32 {
    bytes := buffer.bytes;
    if from <= 0 return 0;

    offset := from - 1;
    while offset > 0 && vim_char_class(bytes[offset], big) == .space {
        if bytes[offset] == #char "\n" && bytes[offset - 1] == #char "\n" return offset;
        offset -= 1;
    }

    class := vim_char_class(bytes[offset], big);
    while offset > 0 && vim_char_class(bytes[offset - 1], big) == class offset -= 1;
    return offset;
}

vim_paragraph_forward :: (buffer: *Buffer, from: s32) -> s32 {
    max_line := get_max_real_line_num(buffer);
    line := offset_to_real_line(buffer, from);
    while line < max_line && is_empty(buffer, line) line += 1;
    while line < max_line {
        line += 1;
        if is_empty(buffer, line) return get_real_line_start_offset(buffer, line);
    }
    return cast(s32) buffer.bytes.count;
}

vim_paragraph_backward :: (buffer: *Buffer, from: s32) -> s32 {
    line := offset_to_real_line(buffer, from);
    while line > 0 && is_empty(buffer, line) line -= 1;
    while line > 0 {
        line -= 1;
        if is_empty(buffer, line) return get_real_line_start_offset(buffer, line);
    }
    return 0;
}

vim_bracket_partner :: (byte: u8) -> partner: u8, forward: bool, is_bracket: bool {
    if byte == {
        case #char "("; return #char ")", true,  true;
        case #char "["; return #char "]", true,  true;
        case #char "{"; return #char "}", true,  true;
        case #char ")"; return #char "(", false, true;
        case #char "]"; return #char "[", false, true;
        case #char "}"; return #char "{", false, true;
    }
    return 0, false, false;
}

vim_matching_bracket :: (buffer: *Buffer, from: s32) -> s32, found: bool {
    bytes := buffer.bytes;
    end := get_real_line_end_offset(buffer, offset_to_real_line(buffer, from));

    offset := from;
    while offset < end {
        _, _, is_bracket := vim_bracket_partner(bytes[offset]);
        if is_bracket break;
        offset += 1;
    }
    if offset >= end return from, false;

    byte := bytes[offset];
    partner, forward := vim_bracket_partner(byte);

    step := ifx forward then 1 else -1;
    depth := 0;
    while offset >= 0 && offset < bytes.count {
        if bytes[offset] == byte then depth += 1;
        else if bytes[offset] == partner {
            depth -= 1;
            if depth == 0 return offset, true;
        }
        offset += cast(s32) step;
    }
    return from, false;
}

vim_reversed_find :: (motion: Vim_Motion) -> Vim_Motion {
    if motion == {
        case .find_forward;  return .find_backward;
        case .find_backward; return .find_forward;
        case .till_forward;  return .till_backward;
        case .till_backward; return .till_forward;
    }
    return motion;
}

vim_find_char_target :: (buffer: *Buffer, from: s32, motion: Vim_Motion, char: u32, count: s32, repeating: bool) -> Vim_Target {
    utf8_char := convert_utf32_to_utf8(char);
    needle := to_string(*utf8_char);

    forward := motion == .find_forward || motion == .till_forward;
    till    := motion == .till_forward || motion == .till_backward;

    line := offset_to_real_line(buffer, from);
    line_start := get_real_line_start_offset(buffer, line);
    line_end   := get_real_line_end_offset(buffer, line);
    text := to_string(buffer.bytes);

    miss := Vim_Target.{ offset = from, found = false };

    offset := from;
    if till && repeating {
        if forward then offset = min(offset + 1, line_end);
        else offset = max(offset - 1, line_start);
    }

    for 1 .. count {
        found := false;
        if forward {
            offset += 1;
            while offset < line_end {
                if slice(text, offset, needle.count) == needle { found = true; break; }
                offset += 1;
            }
        } else {
            offset -= 1;
            while offset >= line_start {
                if slice(text, offset, needle.count) == needle { found = true; break; }
                offset -= 1;
            }
        }
        if !found return miss;
    }

    if till {
        if forward then offset = prev_char_offset(buffer.bytes, offset);
        else offset = next_char_offset(buffer.bytes, offset);
    }

    return .{ offset = offset, kind = ifx forward then Vim_Motion_Kind.inclusive else .exclusive, found = true };
}

vim_search_target :: (from: s32, forward: bool, count: s32) -> s32, found: bool {
    editor := get_active_editor_and_buffer();
    if !editor return from, false;
    offset, found := vim_search_target_in_bar(*editor.search_bar, from, forward, count, skip_current = true);
    return offset, found;
}

vim_search_target_in_bar :: (bar: *Search_Bar, from: s32, forward: bool, count: s32, skip_current: bool) -> s32, found: bool {
    total := bar.results.count;
    if !total return from, false;

    offset := from;
    for 1 .. count {
        chosen := -1;
        if forward {
            for result, result_index : bar.results {
                if result.offset > offset || (!skip_current && result.offset == offset) {
                    chosen = result_index;
                    break;
                }
            }
            if chosen < 0 then chosen = 0;
        } else {
            for < result_index : 0 .. total - 1 {
                result := bar.results[result_index];
                if result.offset < offset || (!skip_current && result.offset == offset) {
                    chosen = result_index;
                    break;
                }
            }
            if chosen < 0 then chosen = total - 1;
        }
        offset = bar.results[chosen].offset;
        bar.selected_result = cast(s32) chosen;
    }
    return offset, true;
}

vim_word_object :: (buffer: *Buffer, at: s32, around: bool) -> Offset_Range, found: bool {
    bytes := buffer.bytes;
    count := cast(s32) bytes.count;
    if at >= count return .{}, false;

    line_end := get_real_line_end_offset(buffer, offset_to_real_line(buffer, at));
    if at == line_end return .{ at, at }, true;

    class := vim_char_class(bytes[at], false);
    start := at;
    end   := at;
    while start > 0 && bytes[start - 1] != #char "\n" && vim_char_class(bytes[start - 1], false) == class start -= 1;
    while end < line_end && vim_char_class(bytes[end], false) == class end += 1;

    if around {
        if class == .space {
            if end < line_end {
                next_class := vim_char_class(bytes[end], false);
                while end < line_end && vim_char_class(bytes[end], false) == next_class end += 1;
            }
        } else {
            before_trailing := end;
            while end < line_end && vim_char_class(bytes[end], false) == .space end += 1;
            if end == before_trailing {
                while start > 0 && bytes[start - 1] != #char "\n" && vim_char_class(bytes[start - 1], false) == .space start -= 1;
            }
        }
    }

    return .{ start, end }, true;
}

vim_pair_object :: (buffer: *Buffer, at: s32, open: u8, close: u8, around: bool) -> Offset_Range, found: bool {
    bytes := buffer.bytes;
    count := cast(s32) bytes.count;
    if !count return .{}, false;

    start := min(at, count - 1);
    if bytes[start] != open {
        depth := 0;
        if bytes[start] == close then start -= 1;
        while start >= 0 {
            if bytes[start] == close then depth += 1;
            else if bytes[start] == open {
                if depth == 0 break;
                depth -= 1;
            }
            start -= 1;
        }
        if start < 0 return .{}, false;
    }

    end := start + 1;
    depth := 0;
    while end < count {
        if bytes[end] == open then depth += 1;
        else if bytes[end] == close {
            if depth == 0 break;
            depth -= 1;
        }
        end += 1;
    }
    if end >= count return .{}, false;

    if around return .{ start, end + 1 }, true;

    inner_start := start + 1;
    inner_end   := end;
    if inner_start < count && bytes[inner_start] == #char "\n" {
        inner_start += 1;
        closer_line := offset_to_real_line(buffer, end);
        if vim_first_nonblank(buffer, closer_line) == end {
            inner_end = get_real_line_start_offset(buffer, closer_line);
        }
    }
    return .{ inner_start, max(inner_start, inner_end) }, true;
}

vim_quote_object :: (buffer: *Buffer, at: s32, quote: u8, around: bool) -> Offset_Range, found: bool {
    bytes := buffer.bytes;
    line := offset_to_real_line(buffer, at);
    line_start := get_real_line_start_offset(buffer, line);
    line_end   := get_real_line_end_offset(buffer, line);

    offset := line_start;
    open: s32 = -1;
    while offset < line_end {
        if bytes[offset] == #char "\\" {
            offset += 2;
            continue;
        }
        if bytes[offset] == quote {
            if open < 0 {
                open = offset;
            } else {
                if at <= offset {
                    if !around return .{ open + 1, offset }, true;
                    end := offset + 1;
                    while end < line_end && (bytes[end] == #char " " || bytes[end] == #char "\t") end += 1;
                    return .{ open, end }, true;
                }
                open = -1;
            }
        }
        offset += 1;
    }
    return .{}, false;
}
