Vim_Command_Line_Kind :: enum u8 {
    ex;
    search_forward;
    search_backward;
}

Vim_Ex_Command :: enum u8 {
    edit;
    write;
    write_all;
    quit;
    quit_all;
    write_quit;
    write_quit_all;
    exit_if_modified;
    vertical_split;
    horizontal_split;
    next_buffer;
    previous_buffer;
    delete_buffer;
    clear_search;
    substitute;
}

Vim_Ex_Name :: struct {
    name:    string;
    command: Vim_Ex_Command;
}

VIM_EX_NAMES :: Vim_Ex_Name.[
    .{ "e",       .edit },
    .{ "edit",    .edit },
    .{ "w",       .write },
    .{ "write",   .write },
    .{ "wa",      .write_all },
    .{ "wall",    .write_all },
    .{ "q",       .quit },
    .{ "quit",    .quit },
    .{ "qa",      .quit_all },
    .{ "qall",    .quit_all },
    .{ "wq",      .write_quit },
    .{ "wqa",     .write_quit_all },
    .{ "wqall",   .write_quit_all },
    .{ "xa",      .write_quit_all },
    .{ "xall",    .write_quit_all },
    .{ "x",       .exit_if_modified },
    .{ "xit",     .exit_if_modified },
    .{ "vs",      .vertical_split },
    .{ "vsplit",  .vertical_split },
    .{ "sp",      .horizontal_split },
    .{ "split",   .horizontal_split },
    .{ "bn",      .next_buffer },
    .{ "bnext",   .next_buffer },
    .{ "bp",      .previous_buffer },
    .{ "bprev",   .previous_buffer },
    .{ "bd",      .delete_buffer },
    .{ "bdelete", .delete_buffer },
    .{ "noh",     .clear_search },
    .{ "nohlsearch", .clear_search },
    .{ "s",       .substitute },
    .{ "substitute", .substitute },
];

#run {
    for a, a_index : VIM_EX_NAMES {
        for b_index : a_index + 1 .. VIM_EX_NAMES.count - 1 {
            if a.name == VIM_EX_NAMES[b_index].name {
                compiler_report(tprint("Ex command name '%' is defined twice", a.name));
            }
        }
    }
}

Vim_New_File :: struct {
    buffer_id: s64;
    path:      string;
}

vim_command_line: struct {
    input: Text_Input;
    kind:  Vim_Command_Line_Kind;

    saved_cursor: Cursor;

    has_range:  bool;
    range_first: s32;
    range_last:  s32;

    history: [..] string;
    history_index: s64;

    completions: [..] string;
    completion_index: s64;
    completion_prefix: string;
    completion_text: string;

    new_files: [..] Vim_New_File;
};

vim_command_line_label :: () -> string {
    if #complete vim_command_line.kind == {
        case .ex;              return ":";
        case .search_forward;  return "/";
        case .search_backward; return "?";
    }
}

vim_open_ex_line :: (editor: *Editor, buffer: *Buffer) {
    using vim_command_line;

    has_range = vim_is_visual(vim.mode);
    prefill := "";
    if has_range {
        selection := get_selection(editor.cursors[editor.main_cursor]);
        range_first = offset_to_real_line(buffer, selection.start);
        range_last  = offset_to_real_line(buffer, max(selection.end - 1, selection.start));
        prefill = "'<,'>";
    } else if vim.count > 0 {
        prefill = tprint("%", vim.count);
    }

    vim_show_command_line(editor, .ex, prefill);
}

vim_open_search_line :: (editor: *Editor, forward: bool) {
    vim_show_command_line(editor, ifx forward then Vim_Command_Line_Kind.search_forward else .search_backward, "");
}

vim_open_substitute_word :: (editor: *Editor, buffer: *Buffer) {
    probe := editor.cursors[editor.main_cursor];
    select_word(buffer, *probe);
    word := copy_temporary_string(get_selected_string(probe, buffer));
    if !word return;

    vim_command_line.has_range = false;
    vim_show_command_line(editor, .ex, join("%", tprint("s/\\<%\\>/%/gI", word, word),, temp));

    using vim_command_line;
    input.cursor.pos -= 3;
    input.cursor.sel = input.cursor.pos;
}

vim_set_last_search :: (needle: string, forward: bool, whole_word: bool) {
    if vim.last_search then free(vim.last_search);
    vim.last_search = copy_string(needle);
    vim.search_forward = forward;
    vim.search_whole_word = whole_word;
}

vim_command_line_handle_event :: (event: Input.Event) -> handled: bool {
    using vim_command_line;

    if event.type == .TEXT_INPUT {
        text_input_type_char(*input, event.utf32);
        vim_command_line_text_changed();
        return true;
    }

    if event.type != .KEYBOARD || !event.key_pressed return false;

    no_modifiers := !event.ctrl_pressed && !event.cmd_meta_pressed && !event.alt_pressed;

    if event.key_code == .ESCAPE || (event.ctrl_pressed && event.key_code == cast(Input.Key_Code) #char "[") {
        vim_command_line_cancel();
        return true;
    }

    if no_modifiers {
        if event.key_code == {
            case .ENTER;
                vim_command_line_submit();
                return true;

            case .TAB;
                if kind == .ex then vim_complete_path(event.shift_pressed);
                return true;

            case .BACKSPACE;
                if !input.text.count {
                    vim_command_line_cancel();
                    return true;
                }

            case .ARROW_UP;
                vim_walk_history(-1);
                return true;

            case .ARROW_DOWN;
                vim_walk_history(1);
                return true;
        }
    }

    text_before := copy_temporary_string(to_string(input.text));
    handled := text_input_handle_event(*input, event);
    if handled && text_before != to_string(input.text) then vim_command_line_text_changed();
    return handled;
}


vim_forget_new_files :: () {
    for vim_command_line.new_files  free(it.path);
    array_reset_keeping_memory(*vim_command_line.new_files);
}

#scope_file

vim_command_line_set_text :: (text: string) {
    using vim_command_line;
    replace_text(*input, text);
    input.cursor.pos = cast(s32) input.text.count;
    input.cursor.sel = input.cursor.pos;
}

vim_show_command_line :: (editor: *Editor, line_kind: Vim_Command_Line_Kind, prefill: string) {
    using vim_command_line;

    target := editor;
    if active_global_widget == .build_panel {
        target = get_visible_editor_and_buffer();
        if !target return;
        activate_editors();
    }

    kind = line_kind;
    saved_cursor = target.cursors[target.main_cursor];
    history_index = history.count;
    vim_reset_completions();

    if vim_is_visual(vim.mode) then vim_set_mode(.normal);

    text_input_fully_clear(*input);
    if prefill then vim_command_line_set_text(prefill);

    vim_set_mode(.command);
}

vim_command_line_cancel :: () {
    using vim_command_line;

    vim_set_mode(.normal);

    if kind != .ex {
        editor := get_active_editor_and_buffer();
        if editor {
            vim_search_clear(editor);
            cursor := leave_only_original_cursor(editor);
            cursor.* = saved_cursor;
            editor.cursor_moved = true;
            editor.scroll_to_cursor = .yes;
        }
    }
}

vim_command_line_text_changed :: () {
    using vim_command_line;

    if kind == .ex return;

    editor, buffer := get_visible_editor_and_buffer();
    if !editor return;

    needle := to_string(input.text);
    if !needle {
        vim_search_clear(editor);
        return;
    }

    vim_search_update(editor, buffer, needle, false);
    vim_search_jump(editor, saved_cursor.pos, kind == .search_forward, skip_current = false);
}

vim_command_line_submit :: () {
    using vim_command_line;

    line := copy_temporary_string(to_string(input.text));

    if line {
        if !history || history[history.count - 1] != line then array_add(*history, copy_string(line));
    }

    vim_set_mode(.normal);
    defer vim.change_pending = false;

    editor, buffer := get_active_editor_and_buffer();
    if !editor {
        if kind == .ex then vim_ex_execute_without_editor(line);
        return;
    }

    if #complete kind == {
        case .ex;
            previous_editor_id := context.current_editor_id;
            context.current_editor_id = get_active_editor_id();
            defer context.current_editor_id = previous_editor_id;
            vim_ex_execute(editor, buffer, line);

        case .search_forward;  #through;
        case .search_backward;
            forward := kind == .search_forward;
            if !line {
                if !vim.last_search return;
                line = copy_temporary_string(vim.last_search);
            }
            vim_set_last_search(line, forward, whole_word = false);
            vim_search_prepare(editor, buffer);
            if !vim_search_jump(editor, saved_cursor.pos, forward) {
                add_user_warning("Pattern not found: %", line, dismiss_in_seconds = 3);
            }
    }
}

vim_walk_history :: (direction: s64) {
    using vim_command_line;
    if !history return;

    history_index = clamp(history_index + direction, 0, history.count);
    text := ifx history_index < history.count then history[history_index] else "";
    vim_command_line_set_text(text);
    vim_command_line_text_changed();
}

vim_ex_execute_without_editor :: (line: string) {
    name, bang, argument := vim_ex_split(line);
    command, known := vim_ex_lookup(name);
    if !known return;

    if command == {
        case .edit;
            vim_ex_edit(null, argument, bang, .in_place);
        case .vertical_split;
            if argument then vim_ex_edit(null, argument, bang, .right);
        case .horizontal_split;
            if argument then vim_ex_edit(null, argument, bang, .bottom);
        case .quit;           #through;
        case .quit_all;
            vim_ex_quit_application(bang);
    }
}

vim_ex_split :: (line: string) -> name: string, bang: bool, argument: string {
    rest := trim(line);

    name := rest;
    name.count = 0;
    while name.count < rest.count && is_alpha(rest[name.count]) name.count += 1;
    advance(*rest, name.count);

    bang := false;
    if rest && rest[0] == #char "!" {
        bang = true;
        advance(*rest, 1);
    }

    return name, bang, trim(rest);
}

vim_ex_lookup :: (name: string) -> Vim_Ex_Command, known: bool {
    for VIM_EX_NAMES {
        if it.name == name return it.command, true;
    }
    return .edit, false;
}

vim_ex_execute :: (editor: *Editor, buffer: *Buffer, raw_line: string) {
    line := trim(raw_line);
    if !line return;

    if is_all_digits(line) {
        vim_go_to_line(editor, buffer, string_to_int(line));
        return;
    }

    range_kind := Vim_Ex_Range.current_line;
    if begins_with(line, "%") {
        range_kind = .whole_file;
        advance(*line, 1);
    } else if begins_with(line, "'<,'>") {
        range_kind = .visual;
        advance(*line, 5);
    }

    name, bang, argument := vim_ex_split(line);
    command, known := vim_ex_lookup(name);
    if !known {
        add_user_error("Not an editor command: %", line, dismiss_in_seconds = 5);
        return;
    }

    if #complete command == {
        case .edit;              vim_ex_edit(buffer, argument, bang, .in_place);

        case .write;             vim_ex_write(buffer, argument, bang);
        case .write_all;         action_save_all();

        case .quit;              vim_ex_quit_pane(bang);
        case .quit_all;          vim_ex_quit_application(bang);

        case .write_quit;
            if vim_ex_write(buffer, argument, bang) then vim_ex_quit_pane(false);

        case .write_quit_all;
            action_save_all();
            vim_ex_quit_application(false);

        case .exit_if_modified;
            if !buffer.modified || vim_ex_write(buffer, argument, bang) then vim_ex_quit_pane(false);

        case .vertical_split;
            if argument then vim_ex_edit(buffer, argument, bang, .right);
            else action_duplicate_editor(.right);

        case .horizontal_split;
            if argument then vim_ex_edit(buffer, argument, bang, .bottom);
            else action_duplicate_editor(.bottom);

        case .next_buffer;       action_go_to_next_buffer(null);
        case .previous_buffer;   action_go_to_previous_buffer(null);
        case .delete_buffer;     action_close_editor(null);
        case .clear_search;      vim_search_clear(editor);

        case .substitute;        vim_ex_substitute(editor, buffer, range_kind, argument);
    }
}

Vim_Ex_Range :: enum u8 {
    current_line;
    whole_file;
    visual;
}

vim_go_to_line :: (editor: *Editor, buffer: *Buffer, line: s64) {
    go_to_line(editor, buffer, line, 1);
    cursor := *editor.cursors[editor.main_cursor];
    cursor.pos = vim_first_nonblank(buffer, offset_to_real_line(buffer, cursor.pos));
    cursor.sel = cursor.pos;
}

vim_home_directory :: () -> string {
    #if OS == .WINDOWS {
        return "";
    } else {
        POSIX :: #import "POSIX";
        value := POSIX.getenv("HOME");
        if !value return "";
        return to_string(value);
    }
}

vim_path_base_directory :: (buffer: *Buffer) -> string {
    working_directory := get_working_directory();
    has_no_project_directory := working_directory == data_dir || working_directory == "/" || working_directory == "";
    if has_no_project_directory && buffer && buffer.has_file {
        return get_parent_dir_path(buffer.file.full_path);
    }
    return working_directory;
}

vim_expand_path :: (raw: string, buffer: *Buffer) -> string {
    path := replace(trim(raw), "\\ ", " ",, temp);

    if buffer && buffer.has_file {
        if path == "%" then path = buffer.file.full_path;
        else if path == "%:h" then path = get_parent_dir_path(buffer.file.full_path);
        else if begins_with(path, "%:h/") then path = tprint("%/%", get_parent_dir_path(buffer.file.full_path), slice(path, 4, path.count - 4));
    }

    if path == "~" || begins_with(path, "~/") {
        home := vim_home_directory();
        if home then path = tprint("%1%2", home, slice(path, 1, path.count - 1));
    }

    if !is_absolute_path(path) then path = tprint("%/%", vim_path_base_directory(buffer), path);

    if file_exists(path) {
        absolute, success := get_absolute_path(path,, temp);
        if success then path = absolute;
    }

    path = copy_temporary_string(path);
    path_overwrite_separators(path, separator = #char "/");
    return path;
}

vim_ex_edit :: (buffer: *Buffer, argument: string, bang: bool, placement: Editor_Placement) {
    if !argument {
        if !buffer return;
        if buffer.modified && !bang {
            add_user_error("No write since last change (add ! to override)", dismiss_in_seconds = 5);
            return;
        }
        editor := get_active_editor_and_buffer();
        if editor then vim_native(editor, buffer, .reload_from_disk);
        return;
    }

    path := vim_expand_path(argument, buffer);

    is_dir, _ := is_directory(path);
    if is_dir {
        add_user_error("% is a directory", path, dismiss_in_seconds = 5);
        return;
    }

    if file_exists(path) {
        editors_open_file(path, placement);
        return;
    }

    for vim_command_line.new_files {
        if it.path == path {
            editors_open_buffer(it.buffer_id, placement);
            return;
        }
    }

    buffer_id := create_an_empty_buffer();
    new_buffer := *open_buffers[buffer_id];
    new_buffer.lang = get_lang_from_path(path);
    new_buffer.needs_tokenizing = true;
    array_add(*vim_command_line.new_files, Vim_New_File.{ buffer_id = buffer_id, path = copy_string(path) });
    editors_open_buffer(buffer_id, placement);
    add_success_message("New file: %", path, dismiss_in_seconds = 3);
}

vim_remembered_new_file_path :: (buffer: *Buffer) -> string {
    for vim_command_line.new_files {
        if it.buffer_id == buffer.id return it.path;
    }
    return "";
}

vim_ex_write :: (buffer: *Buffer, argument: string, bang: bool) -> success: bool {
    if buffer.readonly || buffer.internal {
        add_user_error("This buffer is read-only", dismiss_in_seconds = 5);
        return false;
    }

    maybe_make_temporary_editor_permanent();

    if !argument {
        if buffer.has_file {
            save(buffer.id);
            return vim_report_write(buffer);
        }

        remembered := vim_remembered_new_file_path(buffer);
        if !remembered {
            add_user_error("No file name", dismiss_in_seconds = 5);
            return false;
        }
        save_buffer_to_file(buffer, remembered);
        return vim_report_write(buffer);
    }

    path := vim_expand_path(argument, buffer);

    if buffer.has_file && platform_path_equals(buffer.file.full_path, path) {
        save(buffer.id);
        return vim_report_write(buffer);
    }

    if file_exists(path) && !bang {
        add_user_error("File exists (add ! to override): %", path, dismiss_in_seconds = 5);
        return false;
    }

    if !buffer.has_file {
        save_buffer_to_file(buffer, path);
        return vim_report_write(buffer);
    }

    contents := get_buffer_contents_for_writing(buffer);
    if !write_entire_file(path, contents) {
        add_user_error("Couldn't write to %", path, dismiss_in_seconds = 5);
        return false;
    }
    add_success_message("Written: %", path, dismiss_in_seconds = 3);
    return true;
}

vim_report_write :: (buffer: *Buffer) -> success: bool {
    if buffer.error_when_saving {
        add_user_error("Couldn't write the file. Does its directory exist?", dismiss_in_seconds = 5);
        return false;
    }
    return true;
}

vim_ex_quit_pane :: (bang: bool) {
    if editors.active_pane && editors.active_pane.parent {
        action_close_pane(.in_place);
        return;
    }
    vim_ex_quit_application(bang);
}

vim_ex_quit_application :: (discard_changes: bool) {
    if discard_changes {
        for * buffer : open_buffers  buffer.modified = false;
    }
    defer_action_quit();
}

vim_ex_substitute :: (editor: *Editor, buffer: *Buffer, range_kind: Vim_Ex_Range, argument: string) {
    if buffer.readonly {
        add_user_error("This buffer is read-only", dismiss_in_seconds = 5);
        return;
    }

    pattern, replacement, flags, parsed := vim_parse_substitute(argument);
    if !parsed {
        add_user_error("Usage: :s/pattern/replacement/[gI]", dismiss_in_seconds = 5);
        return;
    }

    all_on_line := false;
    case_sensitive := contains_uppercase_ascii(pattern);
    for byte : cast([] u8) flags {
        if byte == {
            case #char "g"; all_on_line = true;
            case #char "I"; case_sensitive = true;
            case #char "i"; case_sensitive = false;
            case;
                add_user_error("Unsupported :s flag: %", flags, dismiss_in_seconds = 5);
                return;
        }
    }

    whole_word := begins_with(pattern, "\\<") && ends_with(pattern, "\\>");
    if whole_word then pattern = slice(pattern, 2, pattern.count - 4);
    if !pattern {
        add_user_error("Empty search pattern", dismiss_in_seconds = 5);
        return;
    }

    first, last: s32;
    if #complete range_kind == {
        case .current_line;
            first = offset_to_real_line(buffer, editor.cursors[editor.main_cursor].pos);
            last  = first;
        case .whole_file;
            first = 0;
            last  = get_max_real_line_num(buffer);
        case .visual;
            if !vim_command_line.has_range {
                add_user_warning("No visual selection for this range", dismiss_in_seconds = 3);
                return;
            }
            first = vim_command_line.range_first;
            last  = vim_command_line.range_last;
    }

    matches: [..] s32;
    matches.allocator = temp;

    text := to_string(buffer.bytes);
    for line : first .. last {
        offset := get_real_line_start_offset(buffer, line);
        end    := get_real_line_end_offset(buffer, line);
        while offset + pattern.count <= end {
            if vim_matches_at(text, offset, pattern, case_sensitive) && (!whole_word || is_whole_word(text, offset, pattern.count)) {
                array_add(*matches, offset);
                if !all_on_line break;
                offset += cast(s32) pattern.count;
            } else {
                offset += 1;
            }
        }
    }

    if !matches {
        add_user_warning("Pattern not found: %", pattern, dismiss_in_seconds = 3);
        return;
    }

    vim_edit_group(editor, buffer);

    replaced: String_Builder;
    replaced.allocator = temp;

    span_start := matches[0];
    copied_up_to := span_start;
    for start : matches {
        append(*replaced, slice(text, copied_up_to, start - copied_up_to));
        append(*replaced, replacement);
        copied_up_to = start + cast(s32) pattern.count;
    }

    replace_range(buffer, .{ span_start, copied_up_to }, builder_to_string(*replaced,, allocator = temp));
    vim_sync_buffer(editor, buffer);

    cursor := leave_only_original_cursor(editor);
    delta := (replacement.count - pattern.count) * (matches.count - 1);
    cursor.pos = vim_first_nonblank(buffer, offset_to_real_line(buffer, matches[matches.count - 1] + cast(s32) delta));
    cursor.sel = cursor.pos;
    cursor.col_wanted = -1;

    add_success_message("% substitution(s)", matches.count, dismiss_in_seconds = 3);
}

vim_matches_at :: (text: string, offset: s32, pattern: string, case_sensitive: bool) -> bool {
    candidate := slice(text, offset, pattern.count);
    return ifx case_sensitive then candidate == pattern else equal_nocase(candidate, pattern);
}

vim_parse_substitute :: (argument: string) -> pattern: string, replacement: string, flags: string, parsed: bool {
    if argument.count < 2 return "", "", "", false;
    delimiter := argument[0];

    fields: [3] String_Builder;
    for * fields  it.allocator = temp;

    field := 0;
    index := 1;
    while index < argument.count {
        byte := argument[index];
        if byte == #char "\\" && index + 1 < argument.count && argument[index + 1] == delimiter {
            append(*fields[field], delimiter);
            index += 2;
            continue;
        }
        if byte == delimiter && field < 2 {
            field += 1;
            index += 1;
            continue;
        }
        append(*fields[field], byte);
        index += 1;
    }

    pattern     := builder_to_string(*fields[0],, allocator = temp);
    replacement := builder_to_string(*fields[1],, allocator = temp);
    flags       := builder_to_string(*fields[2],, allocator = temp);
    return pattern, replacement, flags, pattern.count > 0;
}

vim_reset_completions :: () {
    using vim_command_line;
    for completions  free(it);
    array_reset_keeping_memory(*completions);
    completion_index = -1;
    if completion_prefix then free(completion_prefix);
    if completion_text then free(completion_text);
    completion_prefix = "";
    completion_text = "";
}

vim_complete_path :: (backward: bool) {
    using vim_command_line;

    text := to_string(input.text);
    if !completions || text != completion_text {
        vim_build_completions(text);
    }
    if !completions return;

    step := ifx backward then completions.count - 1 else 1;
    completion_index = (max(completion_index, ifx backward then 0 else -1) + step) % completions.count;

    completed := tprint("%1%2", completion_prefix, completions[completion_index]);
    vim_command_line_set_text(completed);

    if completion_text then free(completion_text);
    completion_text = copy_string(completed);
}

vim_build_completions :: (text: string) {
    using vim_command_line;
    vim_reset_completions();

    space := find_index_from_left(text, #char " ");
    if space < 0 return;

    name, _, _ := vim_ex_split(slice(text, 0, space));
    command, known := vim_ex_lookup(name);
    if !known return;
    if command != .edit && command != .write && command != .vertical_split && command != .horizontal_split return;

    argument_start := space + 1;
    argument := slice(text, argument_start, text.count - argument_start);

    last_slash := find_index_from_right(argument, #char "/");
    directory_text := ifx last_slash >= 0 then slice(argument, 0, last_slash + 1) else "";
    name_prefix    := ifx last_slash >= 0 then slice(argument, last_slash + 1, argument.count - last_slash - 1) else argument;

    _, buffer := get_visible_editor_and_buffer();
    directory := vim_expand_path(ifx directory_text then directory_text else ".", buffer);

    Visit_Data :: struct {
        names:  *[..] string;
        prefix: string;
    }
    visitor :: (info: *File_Visit_Info, data: Visit_Data) {
        if !begins_with(info.short_name, data.prefix) return;
        if begins_with(info.short_name, ".") && !begins_with(data.prefix, ".") return;
        array_add(data.names, ifx info.is_directory then sprint("%/", info.short_name) else copy_string(info.short_name));
    }
    visit_files(directory, recursive = false, Visit_Data.{ *completions, name_prefix }, visitor, visit_files = true, visit_directories = true);

    if !completions return;

    quick_sort(completions, compare_strings);

    completion_prefix = copy_string(tprint("%1%2", slice(text, 0, argument_start), directory_text));
}
