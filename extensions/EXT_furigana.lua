local logger = require("logger")

local Furigana = {
    description = "Extracts Furigana and populates it to the specified fields.",
    
    -- These 2 fields should be modified to point to the desired fields on the card
    expression_reading = "ExpressionReading", -- Pure furigana reading "ちせい"
    expression_furigana = "ExpressionFurigana", -- Kanji + Furigana "知性[ちせい]"
}

-- Returns the leading hiragana characters of str, stopping at the first non-hiragana character.
-- Hiragana occupies U+3041–U+309F, which in UTF-8 encodes as:
--   E3 81 [81–BF]  (U+3041–U+307F)
--   E3 82 [80–9F]  (U+3080–U+309F)
-- We compare raw bytes to avoid the UTF-8 byte-collision pitfalls of Lua 5.1 patterns.
local function hiragana_head(str)
    local i = 1
    local len = #str
    
    while i <= len do
        local b1 = str:byte(i)

        if b1 == 0x2D then -- allow ASCII '-'
            i = i + 1
        elseif i + 2 <= len then -- hiragana check
            -- grab all 3 bytes in one operation for hiragana checks
            local _, b2, b3 = str:byte(i, i + 2)
            if b1 == 0xE3 and
              ((b2 == 0x81 and b3 >= 0x81 and b3 <= 0xBF) or
               (b2 == 0x82 and b3 >= 0x80 and b3 <= 0x9F)) then
                i = i + 3
            else
                break
            end
        else
            break
        end
    end
    
    return str:sub(1, i - 1)
end

function Furigana:run(note)
    local queried_word = self.popup_dict and self.popup_dict.word or ""
    logger.info(("EXT: Furigana: queried term: '%s'"):format(queried_word))
    local result = self.popup_dict.results[self.popup_dict.dict_index]
    local definition_preview = (result.definition or "")
        :gsub("\n", " ")
        :sub(1, 160)
    logger.info(("EXT: Furigana: dict='%s' word='%s' definition='%s'\n")
        :format(result.dict or "", result.word or "", definition_preview))

    local furigana = hiragana_head(result.word)
    logger.info(("EXT: Furigana: Extracted furigana '%s'\n")
        :format(furigana))
    -- Populate ExpressionReading and ExpressionFurigana
    -- only if the query is not hiragana
    if furigana ~= queried_word then
        note.fields[self.expression_reading] = furigana
        note.fields[self.expression_furigana] = ("%s[%s]")
            :format(queried_word, furigana)
    end
    return note
end

return Furigana