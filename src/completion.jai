completion_handle_event :: (event: Input.Event) -> handled: bool {
    if event.type == .TEXT_INPUT {
        if completion.active then completion_finish();
        return false;
    }
    if event.type != .KEYBOARD || !event.key_pressed return false;

    completion_refresh();
    if completion.active return completion_handle_key(event);

    if !context.config.settings.autocomplete_on_tab return false;
    if !completion_key_is_indent(event) return false;
    return completion_open();
}

completion_update :: () {
    completion_refresh();
    if !completion.active return;

    if completion.pass != .done {
        slice_start := current_time_monotonic();
        while completion.pass != .done && !completion_slice_expired(slice_start) {
            completion_scan_next_slice(slice_start);
        }
        redraw_requested = true;
    }

    if completion.pending_steps then completion_apply_pending_steps();
    if completion.pass == .done && !completion.items.count then completion_close();
}

completion_close :: () {
    if !completion.active return;
    using completion;
    active = false;
    completion_clear_items();
}

completion: struct {
    active: bool;
    edited: bool;

    editor_id: s64;
    buffer_id: s64;
    cursor_count: s64;
    last_pos: s32;
    last_byte_count: s64;
    record_start: s64;

    needle: string;
    current: string;

    pass: Completion_Pass;
    buffer_index: s64;
    offset: s64;

    items: [..] Completion_Item;
    seen: Table(string, s32);
    order: [..] s32;
    selected_row: s32 = -1;
    pending_steps: s32;

    pool: Flat_Pool;
};

COMPLETION_MAX_ITEMS  :: 10000;
COMPLETION_MAX_WORD   :: 128;
COMPLETION_SLICE_MS   :: 3.0;
COMPLETION_TIME_CHECK_BYTES :: 64 * 1024;

Completion_Tier :: enum u8 {
    file;
    open;
    project;
    language;
}

Completion_Pass :: enum u8 {
    open;
    project;
    done;
}

Completion_Item :: struct {
    word: string;
    distance: s32;
    score: s32;
    tier: Completion_Tier;
    declared: bool;
}

#scope_file

completion_match :: (word: string, needle: string) -> matched: bool, score: s32 {
    if !needle return true, 0;
    if needle.count == 1 && to_lower(word[0]) != to_lower(needle[0]) return false, 0;

    MATCH_CONSECUTIVE :: 5;
    MATCH_LEADING     :: -4;
    MATCH_GAP         :: -1;
    MATCH_BOUNDARY    :: 3;

    next := 0;
    last_match := -1;
    score: s32;
    for 0 .. word.count - 1 {
        if next >= needle.count break;
        if to_lower(word[it]) != to_lower(needle[next]) continue;

        at_boundary := it > 0 && (word[it - 1] == #char "_" || (is_lower(word[it - 1]) && is_upper(word[it])));
        if next == 0 {
            score += cast(s32) it * MATCH_LEADING;
            if at_boundary then score += MATCH_BOUNDARY;
        } else if it == last_match + 1 {
            score += MATCH_CONSECUTIVE;
        } else {
            score += cast(s32) (it - last_match - 1) * MATCH_GAP;
            if at_boundary then score += MATCH_BOUNDARY;
        }

        last_match = it;
        next += 1;
    }
    if next < needle.count return false, 0;

    return true, score;
}

completion_clear_items :: () {
    using completion;
    no_items: [..] Completion_Item;
    no_rows: [..] s32;
    items = no_items;
    order = no_rows;
    seen = .{};
    reset(*pool);

    allocator := allocator_of(*pool);
    items.allocator = allocator;
    order.allocator = allocator;
    seen.allocator = allocator;
}

completion_is_word_char :: inline (byte: u8) -> bool {
    return byte >= 0x80 || ascii_is_alnum(byte);
}

completion_slice_expired :: inline (slice_start: Apollo_Time) -> bool {
    return to_float64_seconds(current_time_monotonic() - slice_start) * 1000 >= COMPLETION_SLICE_MS;
}

completion_key_is_indent :: (event: Input.Event) -> bool {
    if key_sequence_input_in_progress() return false;
    for context.config.keymap.editors {
        if it.key_sequence.count != 1 continue;
        combo := it.key_sequence[0];
        if combo.key_code == xx event.key_code && combo.mods.packed == (event.modifier_flags.packed | combo.ignore.packed) return it.action == xx Action_Editors.indent_or_go_to_next_tabstop;
    }
    return false;
}

completion_handle_key :: (event: Input.Event) -> handled: bool {
    if event.key_code == .SHIFT || event.key_code == .CTRL || event.key_code == .ALT || event.key_code == .CMD || event.key_code == .META return false;

    if completion_key_is_indent(event) {
        completion_step(1);
        return true;
    }
    if event.key_code == .TAB && event.modifier_flags.shift_pressed {
        completion_step(-1);
        return true;
    }

    completion_finish();
    return false;
}

completion_step :: (step: s32) {
    completion.pending_steps += step;
    completion_apply_pending_steps();
}

completion_apply_pending_steps :: () {
    using completion;

    completion_sort_new_items();

    row := selected_row;
    direction: s32 = 1;
    if pending_steps < 0 then direction = -1;
    while pending_steps {
        next := row + direction;
        if next < -1 || next >= order.count {
            if pass != .done break;
            next = ifx direction > 0 then -1 else cast(s32) order.count - 1;
        }
        row = next;
        pending_steps -= direction;
    }
    if row == selected_row return;

    selected_row = row;
    completion_replace_current(ifx row < 0 then needle else items[order[row]].word);
}

completion_replace_current :: (word: string) {
    using completion;

    editor, buffer := get_active_editor_and_buffer();

    context.current_editor_id = get_active_editor_id();
    defer context.current_editor_id = -1;

    if !edited {
        edited = true;
        record_start = vim.current_record.count;

        maybe_make_temporary_editor_permanent();
        if !vim_holds_undo_group() then new_edit_group(buffer, editor);

        remember_cursors_before_first_edit(buffer, editor);
    }

    for :vim_cursors editor {
        start := it.pos - cast(s32) current.count;
        replace_range(buffer, .{ start = start, end = it.pos }, word);
        it.pos = start + cast(s32) word.count;
        it.sel = it.pos;
    }

    vim_sync_buffer(editor, buffer);
    if editor.cursors.count > 1 then organise_cursors(editor);
    for * cursor : editor.cursors  cursor.col_wanted = -1;

    buffer.last_edit_time = frame_time64;
    editor.cursor_moved = true;
    cursors_start_blinking();

    if vim_enabled() {
        vim.current_record.count = record_start;
        vim_record_replacement(needle, word);
    }

    current = word;
    last_pos = editor.cursors[editor.main_cursor].pos;
    last_byte_count = buffer.bytes.count;
}

completion_finish :: () {
    using completion;

    if edited && !vim_holds_undo_group() {
        editor, buffer := get_editor_and_buffer(editor_id);
        if editor.buffer_id == buffer_id then new_edit_group(buffer, editor);
    }
    completion_close();
}

completion_mode_allows_editing :: () -> bool {
    return !vim_enabled() || vim.mode == .insert;
}

completion_word_at_cursors :: (editor: *Editor, buffer: *Buffer) -> ok: bool, typed: string, directive: bool {
    for editor.cursors  if has_selection(it) return false, "", false;

    bytes := buffer.bytes.data;
    pos := editor.cursors[editor.main_cursor].pos;

    start := pos;
    while start > 0 && completion_is_word_char(bytes[start - 1]) start -= 1;

    needle_len := pos - start;
    if needle_len > COMPLETION_MAX_WORD return false, "", false;

    directive := buffer.lang == .Jai && start > 0 && bytes[start - 1] == #char "#";
    if !needle_len && !directive return false, "", false;

    typed := string.{ needle_len, bytes + start };
    for editor.cursors {
        other_start := it.pos - needle_len;
        if other_start < 0 return false, "", false;
        if other_start > 0 && completion_is_word_char(bytes[other_start - 1]) return false, "", false;
        if string.{ typed.count, bytes + other_start } != typed return false, "", false;
    }

    return true, typed, directive;
}

completion_open :: () -> handled: bool {
    using completion;

    if active_global_widget != .editors || !completion_mode_allows_editing() return false;
    editor, buffer := get_active_editor_and_buffer();
    if !editor || editor.search_bar.active || buffer.readonly return false;

    ok, typed, directive := completion_word_at_cursors(editor, buffer);
    if !ok return false;

    if !directive && is_all_digits(typed) return false;

    active = true;
    edited = false;
    editor_id = get_active_editor_id();
    buffer_id = editor.buffer_id;
    cursor_count = editor.cursors.count;
    last_pos = editor.cursors[editor.main_cursor].pos;
    last_byte_count = buffer.bytes.count;
    selected_row = -1;
    pending_steps = 0;

    completion_clear_items();

    needle = copy_string(typed,, allocator_of(*pool));
    current = needle;

    if directive {
        completion_add_language_words(jai_completion_directives());
        pass = .done;
    } else {
        completion_start_scan(editor, buffer);
    }

    completion_step(1);

    return true;
}

completion_start_scan :: (editor: *Editor, buffer: *Buffer) {
    using completion;

    pass = .open;
    buffer_index = 0;
    offset = 0;

    lock(*buffer.content_lock);
    completion_scan_buffer(buffer, .file, editor, 0);
    unlock(*buffer.content_lock);

    if !workspace_scan_complete then completion_finish_scan();
}

completion_scan_next_slice :: (slice_start: Apollo_Time) {
    using completion;

    if buffer_index >= open_buffers.count {
        buffer_index = 0;
        offset = 0;
        if pass == .open pass = .project;
        else             completion_finish_scan();
        return;
    }

    buffer := *open_buffers[buffer_index];
    wanted := buffer_index != buffer_id && !(buffer.deleted && !buffer.modified) && !buffer.binary && !buffer.internal && (pass == .open) == (buffer.num_editors_open > 0);
    if !wanted {
        buffer_index += 1;
        offset = 0;
        return;
    }

    tier := ifx pass == .open then Completion_Tier.open else .project;
    offset = completion_scan_buffer(buffer, tier, null, offset, slice_start);
    if offset >= buffer.bytes.count {
        buffer_index += 1;
        offset = 0;
    }
    if items.count >= COMPLETION_MAX_ITEMS then completion_finish_scan();
}

completion_finish_scan :: () {
    using completion;
    pass = .done;

    _, buffer := get_active_editor_and_buffer();
    if !buffer || buffer.lang != .Jai return;

    keywords := jai_completion_keywords();
    for keywords  completion_add_language_words(it);
}

completion_add_language_words :: (words: [] string) {
    for words {
        matched, score := completion_match(it, completion.needle);
        if matched then completion_add_word(it, .language, S32_MAX, score, false);
    }
}

completion_scan_buffer :: (buffer: *Buffer, tier: Completion_Tier, current_editor: *Editor, start_offset: s64, slice_start := Apollo_Time.{}) -> next_offset: s64 {
    using completion;

    bytes := buffer.bytes.data;
    count := buffer.bytes.count;
    check_declared := buffer.lang == .Jai;

    i := start_offset;
    next_time_check := i + COMPLETION_TIME_CHECK_BYTES;

    while i < count {
        if !current_editor && i >= next_time_check {
            if completion_slice_expired(slice_start) return i;
            next_time_check = i + COMPLETION_TIME_CHECK_BYTES;
        }

        while i < count && !completion_is_word_char(bytes[i]) i += 1;
        if i >= count break;

        word_start := i;
        while i < count && completion_is_word_char(bytes[i]) i += 1;

        length := i - word_start;
        if length > COMPLETION_MAX_WORD || ascii_is_digit(bytes[word_start]) continue;

        word := string.{ length, bytes + word_start };
        matched, score := completion_match(word, needle);
        if !matched continue;

        if current_editor {
            under_a_cursor := false;
            for current_editor.cursors {
                if it.pos >= word_start && it.pos <= i { under_a_cursor = true; break; }
            }
            if under_a_cursor continue;
        }

        declared := false;
        if check_declared {
            after := i + count_whitespace(buffer.bytes, xx i, xx count);
            declared = after < count && bytes[after] == #char ":";
        }

        distance: s32 = S32_MAX;
        if current_editor then distance = cast(s32) abs(word_start - current_editor.cursors[current_editor.main_cursor].pos);

        completion_add_word(word, tier, distance, score, declared);
        if items.count >= COMPLETION_MAX_ITEMS break;
    }

    return count;
}

completion_add_word :: (word: string, tier: Completion_Tier, distance: s32, score: s32, declared: bool) {
    using completion;
    if word == needle return;

    index := table_find_pointer(*seen, word);
    if index {
        item := *items[index.*];
        if distance < item.distance then item.distance = distance;
        item.declared ||= declared;
        return;
    }

    item: Completion_Item;
    item.word = copy_string(word,, allocator_of(*pool));
    item.tier = tier;
    item.distance = distance;
    item.score = score;
    item.declared = declared;
    array_add(*items, item);
    table_add(*seen, item.word, cast(s32) (items.count - 1));
}

completion_sort_new_items :: () {
    using completion;
    first_new := order.count;
    if first_new == items.count return;

    for first_new .. items.count - 1  array_add(*order, cast(s32) it);

    compare :: (a: s32, b: s32) -> s64 {
        left  := *completion.items[a];
        right := *completion.items[b];
        if left.tier != right.tier         return cast(s64) left.tier - cast(s64) right.tier;
        if left.score != right.score       return cast(s64) right.score - cast(s64) left.score;
        if left.distance != right.distance return cast(s64) left.distance - cast(s64) right.distance;
        if left.declared != right.declared return ifx left.declared then -1 else 1;
        if left.word.count != right.word.count return left.word.count - right.word.count;
        return compare_strings(left.word, right.word);
    }
    first_unvisited := selected_row + 1;
    quick_sort(array_view(order, first_unvisited, order.count - first_unvisited), compare);
}

completion_refresh :: () {
    using completion;
    if !active return;

    editor, buffer := get_active_editor_and_buffer();
    if !editor || active_global_widget != .editors || editor.search_bar.active || !completion_mode_allows_editing()
       || get_active_editor_id() != editor_id || editor.buffer_id != buffer_id || editor.cursors.count != cursor_count
       || editor.cursors[editor.main_cursor].pos != last_pos || buffer.bytes.count != last_byte_count
       || last_pos < current.count || string.{ current.count, buffer.bytes.data + last_pos - current.count } != current {
        completion_finish();
    }
}
