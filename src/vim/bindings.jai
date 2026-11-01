Vim_Modes :: enum_flags u8 {
    normal;
    visual;
    visual_line;
    operator_pending;
}

VIM_VISUAL  :: Vim_Modes.visual | .visual_line;
VIM_NV      :: Vim_Modes.normal | VIM_VISUAL;
VIM_MOTIONS :: VIM_NV | .operator_pending;

Vim_Motion :: enum u16 {
    left;
    right;
    down;
    up;
    next_line_start;
    word_forward;
    word_backward;
    word_end;
    big_word_forward;
    big_word_backward;
    big_word_end;
    line_start;
    first_nonblank;
    line_end;
    file_start;
    file_end;
    paragraph_backward;
    paragraph_forward;
    matching_bracket;
    find_forward;
    find_backward;
    till_forward;
    till_backward;
    repeat_find;
    repeat_find_reversed;
    half_page_down;
    half_page_up;
    page_down;
    page_up;
    search_next;
    search_previous;
}

Vim_Text_Object :: enum u16 {
    word;
    parens;
    braces;
    brackets;
    double_quotes;
    single_quotes;
    backticks;
}

Vim_Operator :: enum u16 {
    none;
    delete;
    delete_no_yank;
    change;
    yank;
    indent;
    unindent;
    autoindent;
    comment;
    lowercase;
    uppercase;
    toggle_case;
}

Vim_Action :: enum u16 {
    escape;
    current_line;

    insert_before;
    insert_after;
    insert_line_start;
    insert_line_end;
    open_below;
    open_above;

    enter_visual;
    enter_visual_line;
    swap_visual_ends;
    move_lines_down;
    move_lines_up;

    delete_char;
    delete_char_before;
    delete_to_line_end;
    change_to_line_end;
    yank_to_line_end;
    substitute_char;
    substitute_line;
    replace_char;
    toggle_case_char;
    join_lines;

    paste_after;
    paste_before;
    paste_no_yank;
    undo;
    redo;
    repeat_change;

    open_ex;
    search_forward;
    search_backward;
    search_word_forward;
    search_word_backward;
    substitute_word;

    center_view;
    view_cursor_top;
    view_cursor_bottom;
    jump_back;
    jump_forward;
    next_comment;
    previous_comment;

    add_cursor_below;
    cursors_from_selected_lines;
    cursors_on_all_occurrences;
    remove_additional_cursors;

    find_file;
    search_project;
    search_project_for_word;
    switch_open_files;
    browse_directory;
    build;
    rebuild;
    toggle_build_panel;
    kill_build;
    next_build_error;
    previous_build_error;
    cycle_panes;
    alternate_buffer;
}

Vim_Binding_Kind :: enum u8 {
    motion;
    text_object;
    op;
    action;
}

VIM_MAX_KEYS :: 6;

Vim_Binding :: struct {
    keys:      [VIM_MAX_KEYS] u32;
    key_count: s32;
    modes:     Vim_Modes;
    kind:      Vim_Binding_Kind;
    code:      u16;
    notation:  string;
}

VIM_KEY_NONE      : u32 : 0;
VIM_KEY_BASE      : u32 : 0x110000;
VIM_KEY_ESC       : u32 : VIM_KEY_BASE + 1;
VIM_KEY_ENTER     : u32 : VIM_KEY_BASE + 2;
VIM_KEY_BACKSPACE : u32 : VIM_KEY_BASE + 3;
VIM_KEY_DELETE    : u32 : VIM_KEY_BASE + 4;
VIM_KEY_TAB       : u32 : VIM_KEY_BASE + 5;
VIM_KEY_UP        : u32 : VIM_KEY_BASE + 6;
VIM_KEY_DOWN      : u32 : VIM_KEY_BASE + 7;
VIM_KEY_LEFT      : u32 : VIM_KEY_BASE + 8;
VIM_KEY_RIGHT     : u32 : VIM_KEY_BASE + 9;
VIM_KEY_HOME      : u32 : VIM_KEY_BASE + 10;
VIM_KEY_END       : u32 : VIM_KEY_BASE + 11;
VIM_KEY_PAGE_UP   : u32 : VIM_KEY_BASE + 12;
VIM_KEY_PAGE_DOWN : u32 : VIM_KEY_BASE + 13;
VIM_KEY_CTRL_BASE : u32 : 0x120000;

vim_ctrl_key :: inline (char: u32) -> u32 {
    return VIM_KEY_CTRL_BASE + char;
}

VIM_BINDINGS :: #run vim_build_bindings();

#run vim_validate_bindings(VIM_BINDINGS);

Vim_Lookup_Result :: enum u8 {
    none;
    partial;
    exact;
}

vim_lookup_binding :: (keys: [] u32, mode: Vim_Modes) -> Vim_Lookup_Result, Vim_Binding {
    result := Vim_Lookup_Result.none;
    for binding : VIM_BINDINGS {
        if !(binding.modes & mode) continue;
        if binding.key_count < keys.count continue;

        matches := true;
        for key, key_index : keys {
            if binding.keys[key_index] != key { matches = false; break; }
        }
        if !matches continue;

        if binding.key_count == keys.count return .exact, binding;
        result = .partial;
    }
    return result, .{};
}


#scope_file

vim_build_bindings :: () -> [] Vim_Binding {
    table: [..] Vim_Binding;

    motion :: (keys: string, value: Vim_Motion, modes := VIM_MOTIONS) #expand {
        array_add(*`table, vim_make_binding(keys, modes, .motion, cast(u16) value));
    }
    text_object :: (keys: string, value: Vim_Text_Object) #expand {
        array_add(*`table, vim_make_binding(keys, VIM_VISUAL | .operator_pending, .text_object, cast(u16) value));
    }
    op :: (keys: string, value: Vim_Operator, modes := VIM_NV) #expand {
        array_add(*`table, vim_make_binding(keys, modes, .op, cast(u16) value));
    }
    action :: (keys: string, value: Vim_Action, modes := Vim_Modes.normal) #expand {
        array_add(*`table, vim_make_binding(keys, modes, .action, cast(u16) value));
    }

    motion("h", .left);
    motion("<Left>", .left);
    motion("<BS>", .left);
    motion("l", .right);
    motion("<Right>", .right);
    motion("j", .down);
    motion("<Down>", .down);
    motion("k", .up);
    motion("<Up>", .up);
    motion("<CR>", .next_line_start);
    motion("w", .word_forward);
    motion("b", .word_backward);
    motion("e", .word_end);
    motion("W", .big_word_forward);
    motion("B", .big_word_backward);
    motion("E", .big_word_end);
    motion("0", .line_start);
    motion("<Home>", .line_start);
    motion("^", .first_nonblank);
    motion("$", .line_end);
    motion("<End>", .line_end);
    motion("gg", .file_start);
    motion("G", .file_end);
    motion("{", .paragraph_backward);
    motion("}", .paragraph_forward);
    motion("%", .matching_bracket);
    motion("f", .find_forward);
    motion("F", .find_backward);
    motion("t", .till_forward);
    motion("T", .till_backward);
    motion(";", .repeat_find);
    motion(",", .repeat_find_reversed);
    motion("<C-d>", .half_page_down);
    motion("<C-u>", .half_page_up);
    motion("<PageDown>", .page_down);
    motion("<PageUp>", .page_up);
    motion("n", .search_next);
    motion("N", .search_previous);

    text_object("iw", .word);
    text_object("aw", .word);
    text_object("i(", .parens);
    text_object("i)", .parens);
    text_object("ib", .parens);
    text_object("a(", .parens);
    text_object("a)", .parens);
    text_object("ab", .parens);
    text_object("i{", .braces);
    text_object("i}", .braces);
    text_object("iB", .braces);
    text_object("a{", .braces);
    text_object("a}", .braces);
    text_object("aB", .braces);
    text_object("i[", .brackets);
    text_object("i]", .brackets);
    text_object("a[", .brackets);
    text_object("a]", .brackets);
    text_object("i\"", .double_quotes);
    text_object("a\"", .double_quotes);
    text_object("i'", .single_quotes);
    text_object("a'", .single_quotes);
    text_object("i`", .backticks);
    text_object("a`", .backticks);

    op("d", .delete);
    op("c", .change);
    op("y", .yank);
    op(">", .indent);
    op("<", .unindent);
    op("=", .autoindent);
    op("gc", .comment);
    op("gu", .lowercase);
    op("gU", .uppercase);
    op("g~", .toggle_case);
    op("<leader>d", .delete_no_yank);
    op("x", .delete, VIM_VISUAL);
    op("<Del>", .delete, VIM_VISUAL);
    op("s", .change, VIM_VISUAL);
    op("u", .lowercase, VIM_VISUAL);
    op("U", .uppercase, VIM_VISUAL);
    op("~", .toggle_case, VIM_VISUAL);

    action("<Esc>", .escape, VIM_MOTIONS);
    action("d", .current_line, .operator_pending);
    action("c", .current_line, .operator_pending);
    action("y", .current_line, .operator_pending);
    action(">", .current_line, .operator_pending);
    action("<", .current_line, .operator_pending);
    action("=", .current_line, .operator_pending);
    action("u", .current_line, .operator_pending);
    action("U", .current_line, .operator_pending);
    action("~", .current_line, .operator_pending);

    action("i", .insert_before);
    action("a", .insert_after);
    action("I", .insert_line_start);
    action("A", .insert_line_end);
    action("o", .open_below);
    action("O", .open_above);

    action("v", .enter_visual, VIM_NV);
    action("V", .enter_visual_line, VIM_NV);
    action("o", .swap_visual_ends, VIM_VISUAL);
    action("J", .move_lines_down, VIM_VISUAL);
    action("K", .move_lines_up, VIM_VISUAL);

    action("x", .delete_char);
    action("<Del>", .delete_char);
    action("X", .delete_char_before);
    action("D", .delete_to_line_end);
    action("C", .change_to_line_end);
    action("Y", .yank_to_line_end);
    action("s", .substitute_char);
    action("S", .substitute_line);
    action("r", .replace_char);
    action("~", .toggle_case_char);
    action("J", .join_lines);

    action("p", .paste_after, VIM_NV);
    action("P", .paste_before, VIM_NV);
    action("<leader>p", .paste_no_yank, VIM_VISUAL);
    action("u", .undo);
    action("<C-r>", .redo);
    action(".", .repeat_change);

    action(":", .open_ex, VIM_NV);
    action("/", .search_forward);
    action("?", .search_backward);
    action("*", .search_word_forward);
    action("#", .search_word_backward);
    action("<leader>s", .substitute_word);

    action("zz", .center_view, VIM_NV);
    action("zt", .view_cursor_top, VIM_NV);
    action("zb", .view_cursor_bottom, VIM_NV);
    action("<C-o>", .jump_back);
    action("<C-i>", .jump_forward);
    action("]c", .next_comment, VIM_NV);
    action("[c", .previous_comment, VIM_NV);

    action("Q", .add_cursor_below);
    action("Q", .cursors_from_selected_lines, VIM_VISUAL);
    action("<leader>Q", .cursors_on_all_occurrences);
    action("<C-l>", .remove_additional_cursors, VIM_NV);

    action("<leader>ff", .find_file);
    action("<leader>/", .search_project, VIM_NV);
    action("<leader>.", .search_project, VIM_NV);
    action("<leader>pws", .search_project_for_word);
    action("<leader>fb", .switch_open_files);
    action("<leader>pv", .browse_directory);
    action("-", .browse_directory);
    action("<leader>b", .build);
    action("<leader>r", .rebuild);
    action("<leader>o", .toggle_build_panel);
    action("<leader>x", .kill_build);
    action("<C-k>", .next_build_error);
    action("<C-j>", .previous_build_error);
    action("<C-,>", .cycle_panes);
    action("<C-.>", .alternate_buffer);

    return table;
}

vim_make_binding :: (notation: string, modes: Vim_Modes, kind: Vim_Binding_Kind, code: u16) -> Vim_Binding {
    binding := Vim_Binding.{ modes = modes, kind = kind, code = code, notation = notation };

    add_key :: (key: u32) #expand {
        if `binding.key_count == VIM_MAX_KEYS {
            compiler_report(tprint("Vim binding '%' has more than % keys", notation, VIM_MAX_KEYS));
            return;
        }
        `binding.keys[`binding.key_count] = key;
        `binding.key_count += 1;
    }

    rest := notation;
    while rest {
        if rest[0] == #char "<" {
            close := find_index_from_left(rest, #char ">");
            if close > 1 {
                key, known := vim_special_key(slice(rest, 0, close + 1));
                if !known {
                    compiler_report(tprint("Vim binding '%' uses an unknown key name", notation));
                    return binding;
                }
                add_key(key);
                advance(*rest, close + 1);
                continue;
            }
        }
        add_key(cast(u32) rest[0]);
        advance(*rest, 1);
    }

    return binding;
}

vim_special_key :: (name: string) -> key: u32, known: bool {
    if name == {
        case "<leader>";   return #char " ",          true;
        case "<Esc>";      return VIM_KEY_ESC,        true;
        case "<CR>";       return VIM_KEY_ENTER,      true;
        case "<BS>";       return VIM_KEY_BACKSPACE,  true;
        case "<Del>";      return VIM_KEY_DELETE,     true;
        case "<Up>";       return VIM_KEY_UP,         true;
        case "<Down>";     return VIM_KEY_DOWN,       true;
        case "<Left>";     return VIM_KEY_LEFT,       true;
        case "<Right>";    return VIM_KEY_RIGHT,      true;
        case "<Home>";     return VIM_KEY_HOME,       true;
        case "<End>";      return VIM_KEY_END,        true;
        case "<PageUp>";   return VIM_KEY_PAGE_UP,    true;
        case "<PageDown>"; return VIM_KEY_PAGE_DOWN,  true;
    }
    if name.count == 5 && begins_with(name, "<C-") return vim_ctrl_key(name[3]), true;
    return VIM_KEY_NONE, false;
}

vim_validate_bindings :: (table: [] Vim_Binding) {
    for a, a_index : table {
        for b_index : a_index + 1 .. table.count - 1 {
            b := table[b_index];
            if !(a.modes & b.modes) continue;

            shared := min(a.key_count, b.key_count);
            same_prefix := true;
            for 0 .. shared - 1 {
                if a.keys[it] != b.keys[it] { same_prefix = false; break; }
            }
            if !same_prefix continue;

            if a.key_count == b.key_count {
                compiler_report(tprint("Vim binding '%' is defined twice for the same mode", a.notation));
            } else {
                compiler_report(tprint("Vim bindings '%' and '%' conflict: one is a prefix of the other in the same mode", a.notation, b.notation));
            }
        }
    }
}
