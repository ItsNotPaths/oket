package main

import "core:os"
import "core:path/filepath"
import "core:strings"

STAGE_BAKED :: string(#load("../../plugins/stage.sh"))

PLUGINIFY_SCRIPT :: "stage.sh"

stage_script_path :: proc(a: ^App) -> string {
    return stage_script_for_dir(a.home.data)
}

stage_script_for_dir :: proc(dir: string) -> string {
    if dir == "" {
        return ""
    }
    path, _ := filepath.join({dir, PLUGINIFY_SCRIPT}, context.temp_allocator)
    if os.exists(path) {
        return path
    }
    if len(STAGE_BAKED) == 0 {
        return path
    }
    _ = os.make_directory_all(dir)
    if os.write_entire_file(path, transmute([]u8)STAGE_BAKED) == nil {
        os.change_mode(path, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
        return path
    }
    f, err := os.create_temp_file("", "oket-stage-*")
    if err != nil {
        return path
    }
    if _, werr := os.write(f, transmute([]u8)STAGE_BAKED); werr != nil {
        os.close(f)
        os.remove(os.name(f))
        return path
    }
    tmp := strings.clone(os.name(f), context.temp_allocator)
    os.close(f)
    os.change_mode(tmp, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
    return tmp
}

stage_ensure_installed :: proc(data_dir: string) {
    if data_dir == "" || len(STAGE_BAKED) == 0 {
        return
    }
    path, _ := filepath.join({data_dir, PLUGINIFY_SCRIPT}, context.temp_allocator)
    if os.exists(path) {
        return
    }
    _ = os.make_directory_all(data_dir)
    if os.write_entire_file(path, transmute([]u8)STAGE_BAKED) == nil {
        os.change_mode(path, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
    }
}
