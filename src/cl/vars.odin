package cl

import "core:strings"

// The fields under point a line can name, as `$o_path` and so on. Fixed here: a plugin publishes
// a field under one of these names or a line cannot reach it. The prefix keeps clear of zsh's
// `$path`.
VARS :: [?]string{"path", "name", "link", "act"}

// One value per name, nil where nothing under point carries it.
Vars :: [len(VARS)]Maybe(string)

var_index :: proc(name: string) -> (int, bool) {
    for v, i in VARS {
        if v == name {
            return i, true
        }
    }
    return 0, false
}

// The next `$o_name` in s: what comes before it, the name, and what is left.
var_next :: proc(s: string) -> (before, name, rest: string, ok: bool) {
    lo := strings.index(s, "$o_")
    if lo < 0 {
        return s, "", "", false
    }
    hi := lo + 3
    for hi < len(s) && (s[hi] >= 'a' && s[hi] <= 'z' || s[hi] == '_') {
        hi += 1
    }
    return s[:lo], s[lo + 3:hi], s[hi:], true
}

// Every `$o_name` in text as ONE argument, quoted when it would re-parse. The first name vars
// lack stops it and comes back as `missing`.
fill :: proc(vars: Vars, text: string, alloc := context.temp_allocator) -> (out, missing: string, ok: bool) {
    b := strings.builder_make(alloc)
    rest := text
    for {
        before, name, tail, found := var_next(rest)
        strings.write_string(&b, before)
        if !found {
            break
        }
        i, known := var_index(name)
        value, set := vars[i].?
        if !known || !set {
            return "", name, false
        }
        strings.write_string(&b, sh_arg(value, alloc))
        rest = tail
    }
    return strings.to_string(b), "", true
}

// The statement a shell step opens with. N0 is one long-lived shell, so every name is set or
// unset each time and none lingers from the step before.
sh_vars :: proc(vars: Vars, alloc := context.temp_allocator) -> string {
    b := strings.builder_make(alloc)
    strings.write_string(&b, "unset")
    for name in VARS {
        strings.write_string(&b, " o_")
        strings.write_string(&b, name)
    }
    strings.write_string(&b, "; ")
    for name, i in VARS {
        if value, set := vars[i].?; set {
            strings.write_string(&b, "o_")
            strings.write_string(&b, name)
            strings.write_byte(&b, '=')
            strings.write_string(&b, sh_quote(value, alloc))
            strings.write_string(&b, "; ")
        }
    }
    return strings.to_string(b)
}

// The first name a step needs that vars lack.
vars_missing :: proc(ch: ^Chain) -> (string, bool) {
    for s in ch.steps {
        if _, name, ok := fill(ch.vars, s.text); !ok {
            return name, true
        }
    }
    return "", false
}

// Owned copies, replacing the last set.
vars_set :: proc(ch: ^Chain, vars: Vars) {
    vars_free(ch)
    for v, i in vars {
        if value, set := v.?; set {
            ch.vars[i] = strings.clone(value)
        }
    }
}

@(private)
vars_free :: proc(ch: ^Chain) {
    for v in ch.vars {
        delete(v.? or_else "")
    }
    ch.vars = {}
}
