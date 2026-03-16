local logger = require("logger")
local u = require("lua_utils/utils")

local LocalAudio = {
    schema_cache = {},
}

local TERM_COLS = { "term", "word", "expression", "lookup", "surface", "headword" }
local AUDIO_COLS = { "audio", "blob", "data", "audio_blob", "content", "bytes" }
local FORMAT_COLS = { "format", "ext", "extension", "codec" }
local MIME_COLS = { "mime", "mimetype", "content_type" }
local LANG_COLS = { "language", "lang" }
local SOURCE_COLS = { "source", "dictionary", "dict" }
local ORDER_COLS = { "updated_at", "created_at", "timestamp", "ts", "id" }

local function sh_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function sql_quote(s)
    return "'" .. tostring(s):gsub("'", "''") .. "'"
end

local function ident(name)
    return '"' .. tostring(name):gsub('"', '""') .. '"'
end

local function pick_col(colset, candidates)
    for _, name in ipairs(candidates) do
        if colset[name] then
            return colset[name]
        end
    end
end

local function hex_to_bytes(hex)
    if not hex or #hex == 0 then
        return nil
    end
    local even_len = #hex - (#hex % 2)
    local truncated = hex:sub(1, even_len)
    return (truncated:gsub("%x%x", function(cc)
        return string.char(tonumber(cc, 16))
    end))
end

-- Detect audio format from filename extension, metadata hints, and magic bytes.
local function detect_ext(filename, format, mime, data)
    -- Prefer the extension embedded in the filename (e.g. "audio/20180222.mp3" -> "mp3")
    if filename then
        local fname_ext = filename:match("%.([%a0-9]+)$")
        if fname_ext then
            return fname_ext:lower()
        end
    end
    local hints = ((format or "") .. " " .. (mime or "")):lower()
    if hints:find("opus", 1, true) then return "opus" end
    if hints:find("ogg",  1, true) then return "ogg"  end
    if hints:find("mp3",  1, true) then return "mp3"  end
    if hints:find("wav",  1, true) then return "wav"  end
    if hints:find("m4a",  1, true) or hints:find("aac", 1, true) then return "m4a" end
    if data and #data >= 4 then
        local magic4 = data:sub(1, 4)
        if magic4 == "OggS" then
            if data:find("OpusHead", 1, true) then return "opus" end
            return "ogg"
        end
        if magic4 == "RIFF" then return "wav" end
        if magic4:sub(1, 3) == "ID3" then return "mp3" end
    end
    return "opus"
end

local function sqlite_cmd_available()
    local output = u.run_cmd("command -v sqlite3 2>/dev/null")
    return output and output[1] ~= nil
end

local function run_sql(db_path, sql)
    local cmd = string.format("sqlite3 -tabs -noheader %s %s 2>/dev/null", sh_quote(db_path), sh_quote(sql))
    return u.run_cmd(cmd)
end

local function get_colset(db_path, table_name)
    local info_rows = run_sql(db_path, "PRAGMA table_info(" .. sql_quote(table_name) .. ");")
    local colset = {}
    for _, row in ipairs(info_rows) do
        local fields = u.split(row, "\t")
        local name = fields[2]
        if name then colset[name:lower()] = name end
    end
    return colset
end

local function collect_table_specs(db_path)
    local tables_output = run_sql(db_path, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")
    local table_names = {}
    for _, t in ipairs(tables_output) do
        if #t > 0 then table_names[t] = true end
    end

    -- Local Audio Server specific schema: entries(expression,file) JOIN android(file,data)
    if table_names["entries"] and table_names["android"] then
        logger.info("localaudio: detected Local Audio Server schema (entries + android)")
        return { { kind = "local_audio_server" } }
    end

    -- Generic single-table fallback
    local specs = {}
    for table_name, _ in pairs(table_names) do
        local colset = get_colset(db_path, table_name)
        local term_col  = pick_col(colset, TERM_COLS)
        local audio_col = pick_col(colset, AUDIO_COLS)
        if term_col and audio_col then
            table.insert(specs, {
                kind       = "single_table",
                table      = table_name,
                term_col   = term_col,
                audio_col  = audio_col,
                format_col = pick_col(colset, FORMAT_COLS),
                mime_col   = pick_col(colset, MIME_COLS),
                lang_col   = pick_col(colset, LANG_COLS),
                source_col = pick_col(colset, SOURCE_COLS),
                order_col  = pick_col(colset, ORDER_COLS),
            })
        end
    end
    return specs
end

local function lookup_local_audio_server(db_path, word)
    local sql = (
        "SELECT hex(a.data), e.file FROM android a" ..
        " JOIN entries e ON a.file = e.file" ..
        " WHERE e.expression = " .. sql_quote(word) ..
        " LIMIT 1;"
    )
    local rows = run_sql(db_path, sql)
    if #rows == 0 then return nil end

    local parts     = u.split(rows[1], "\t")
    local audio_hex = parts[1]
    local filename  = parts[2]
    local audio_data = hex_to_bytes(audio_hex)
    if not audio_data or #audio_data == 0 then return nil end

    return {
        data   = audio_data,
        ext    = detect_ext(filename, nil, nil, audio_data),
        source = "local_audio_server",
        table  = "android",
    }
end

local function lookup_in_table(db_path, spec, word, language)
    local select_cols = { "hex(" .. ident(spec.audio_col) .. ")" }
    if spec.format_col then
        table.insert(select_cols, ident(spec.format_col))
    end
    if spec.mime_col then
        table.insert(select_cols, ident(spec.mime_col))
    end
    if spec.source_col then
        table.insert(select_cols, ident(spec.source_col))
    end

    local sql = {
        "SELECT ",
        table.concat(select_cols, ", "),
        " FROM ", ident(spec.table),
        " WHERE ", ident(spec.term_col), " = ", sql_quote(word),
    }

    if language and spec.lang_col then
        table.insert(sql, " AND ")
        table.insert(sql, ident(spec.lang_col))
        table.insert(sql, " LIKE ")
        table.insert(sql, sql_quote(language .. "%"))
    end

    if spec.order_col then
        table.insert(sql, " ORDER BY ")
        table.insert(sql, ident(spec.order_col))
        table.insert(sql, " DESC")
    end

    table.insert(sql, " LIMIT 1;")

    local rows = run_sql(db_path, table.concat(sql))
    if #rows == 0 then
        return nil
    end

    local parts = u.split(rows[1], "\t")
    local audio_hex = parts[1]
    local audio_data = hex_to_bytes(audio_hex)
    if not audio_data or #audio_data == 0 then
        return nil
    end

    local format_hint = parts[2]
    local mime_hint   = parts[3]
    local source_hint = parts[4]

    return {
        data   = audio_data,
        ext    = detect_ext(nil, format_hint, mime_hint, audio_data),
        source = source_hint,
        table  = spec.table,
    }
end

function LocalAudio:get_audio_blob(db_path, word, language)
    if not db_path or #db_path == 0 then
        return true, nil
    end
    if not u.path_exists(db_path) then
        logger.info(("Local audio db not found at path: %s"):format(db_path))
        return true, nil
    end
    if not sqlite_cmd_available() then
        return false, "sqlite3 command not available"
    end

    local specs = self.schema_cache[db_path]
    if not specs then
        specs = collect_table_specs(db_path)
        self.schema_cache[db_path] = specs
    end

    if #specs == 0 then
        logger.warn(("Local audio db has no supported schema: %s"):format(db_path))
        return true, nil
    end

    for _, spec in ipairs(specs) do
        local result
        if spec.kind == "local_audio_server" then
            result = lookup_local_audio_server(db_path, word)
        else
            result = lookup_in_table(db_path, spec, word, language)
        end
        if result then
            return true, result
        end
    end
    return true, nil
end

return LocalAudio
