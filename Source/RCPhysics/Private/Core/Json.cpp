#include "RCPhysics/Core/Json.h"

#include <cstdlib>
#include <fstream>
#include <sstream>

namespace rc
{
// ------------------------------------------------------------ JsonValue -----

const JsonValue& JsonValue::NullValue()
{
    static const JsonValue kNull;
    return kNull;
}

bool JsonValue::AsBool(bool fallback) const
{
    return (ValueType == Type::Bool) ? BoolValue : fallback;
}

Real JsonValue::AsNumber(Real fallback) const
{
    return (ValueType == Type::Number) ? NumberValue : fallback;
}

std::string JsonValue::AsString(const std::string& fallback) const
{
    return (ValueType == Type::String) ? StringValue : fallback;
}

const JsonArray& JsonValue::AsArray() const
{
    static const JsonArray kEmpty;
    return (ValueType == Type::Array) ? ArrayValue : kEmpty;
}

const JsonObject& JsonValue::AsObject() const
{
    static const JsonObject kEmpty;
    return (ValueType == Type::Object) ? ObjectValue : kEmpty;
}

const JsonValue& JsonValue::operator[](const std::string& key) const
{
    if (ValueType != Type::Object) { return NullValue(); }
    const auto it = ObjectValue.find(key);
    return (it != ObjectValue.end()) ? it->second : NullValue();
}

bool JsonValue::Has(const std::string& key) const
{
    return ValueType == Type::Object && ObjectValue.find(key) != ObjectValue.end();
}

const JsonValue& JsonValue::At(size_t index) const
{
    if (ValueType != Type::Array || index >= ArrayValue.size()) { return NullValue(); }
    return ArrayValue[index];
}

size_t JsonValue::Size() const
{
    if (ValueType == Type::Array)  { return ArrayValue.size(); }
    if (ValueType == Type::Object) { return ObjectValue.size(); }
    return 0;
}

Real JsonValue::GetNumber(const std::string& key, Real fallback) const
{
    return (*this)[key].AsNumber(fallback);
}

bool JsonValue::GetBool(const std::string& key, bool fallback) const
{
    return (*this)[key].AsBool(fallback);
}

std::string JsonValue::GetString(const std::string& key, const std::string& fallback) const
{
    return (*this)[key].AsString(fallback);
}

bool JsonValue::GetVector3(const std::string& key, Real& outX, Real& outY, Real& outZ) const
{
    const JsonValue& v = (*this)[key];
    if (!v.IsArray() || v.Size() != 3) { return false; }
    for (size_t i = 0; i < 3; ++i)
    {
        if (!v.At(i).IsNumber()) { return false; }
    }
    outX = v.At(0).AsNumber();
    outY = v.At(1).AsNumber();
    outZ = v.At(2).AsNumber();
    return true;
}

bool JsonValue::GetNumberArray(const std::string& key, std::vector<Real>& outValues) const
{
    const JsonValue& v = (*this)[key];
    if (!v.IsArray()) { return false; }

    std::vector<Real> parsed;
    parsed.reserve(v.Size());
    for (size_t i = 0; i < v.Size(); ++i)
    {
        if (!v.At(i).IsNumber()) { return false; }
        parsed.push_back(v.At(i).AsNumber());
    }
    outValues = std::move(parsed);
    return true;
}

// -------------------------------------------------------- JsonParseResult ---

std::string JsonParseResult::Describe() const
{
    if (Success) { return "ok"; }
    std::ostringstream out;
    out << "line " << Line << ", column " << Column << ": " << Error;
    return out.str();
}

// ---------------------------------------------------------------- Parser ----

namespace
{
class Parser
{
public:
    Parser(const std::string& text, JsonParseResult& result)
        : Text(text), Result(result) {}

    JsonValue Run()
    {
        SkipWhitespaceAndComments();
        JsonValue root;
        if (!ParseValue(root, 0)) { return JsonValue(); }

        SkipWhitespaceAndComments();
        if (Cursor != Text.size())
        {
            return Fail("trailing content after the top-level value");
        }
        Result.Success = true;
        return root;
    }

private:
    static constexpr int kMaxDepth = 64;

    JsonValue Fail(const char* message)
    {
        if (Result.Error.empty())
        {
            Result.Success = false;
            Result.Error   = message;
            Result.Line    = Line;
            Result.Column  = Column;
        }
        return JsonValue();
    }

    bool FailBool(const char* message) { Fail(message); return false; }

    bool AtEnd() const { return Cursor >= Text.size(); }
    char Peek() const  { return AtEnd() ? '\0' : Text[Cursor]; }

    char Advance()
    {
        if (AtEnd()) { return '\0'; }
        const char c = Text[Cursor++];
        if (c == '\n') { ++Line; Column = 1; } else { ++Column; }
        return c;
    }

    void SkipWhitespaceAndComments()
    {
        for (;;)
        {
            while (!AtEnd())
            {
                const char c = Peek();
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r') { Advance(); }
                else { break; }
            }
            if (Cursor + 1 < Text.size() && Text[Cursor] == '/' && Text[Cursor + 1] == '/')
            {
                while (!AtEnd() && Peek() != '\n') { Advance(); }
                continue;
            }
            if (Cursor + 1 < Text.size() && Text[Cursor] == '/' && Text[Cursor + 1] == '*')
            {
                Advance(); Advance();
                while (!AtEnd())
                {
                    if (Cursor + 1 < Text.size() && Text[Cursor] == '*' && Text[Cursor + 1] == '/')
                    {
                        Advance(); Advance();
                        break;
                    }
                    Advance();
                }
                continue;
            }
            return;
        }
    }

    bool Expect(char expected, const char* message)
    {
        SkipWhitespaceAndComments();
        if (Peek() != expected) { return FailBool(message); }
        Advance();
        return true;
    }

    bool ParseValue(JsonValue& out, int depth)
    {
        if (depth > kMaxDepth) { return FailBool("nesting too deep"); }

        SkipWhitespaceAndComments();
        if (AtEnd()) { return FailBool("unexpected end of input"); }

        const char c = Peek();
        switch (c)
        {
            case '{': return ParseObject(out, depth);
            case '[': return ParseArray(out, depth);
            case '"':
            {
                std::string s;
                if (!ParseString(s)) { return false; }
                out = JsonValue(std::move(s));
                return true;
            }
            case 't':
                if (!MatchLiteral("true")) { return FailBool("invalid literal"); }
                out = JsonValue(true);
                return true;
            case 'f':
                if (!MatchLiteral("false")) { return FailBool("invalid literal"); }
                out = JsonValue(false);
                return true;
            case 'n':
                if (!MatchLiteral("null")) { return FailBool("invalid literal"); }
                out = JsonValue();
                return true;
            default:
                return ParseNumber(out);
        }
    }

    bool MatchLiteral(const char* literal)
    {
        for (const char* p = literal; *p != '\0'; ++p)
        {
            if (AtEnd() || Peek() != *p) { return false; }
            Advance();
        }
        return true;
    }

    bool ParseObject(JsonValue& out, int depth)
    {
        if (!Expect('{', "expected '{'")) { return false; }

        JsonObject object;
        SkipWhitespaceAndComments();
        if (Peek() == '}') { Advance(); out = JsonValue(std::move(object)); return true; }

        for (;;)
        {
            SkipWhitespaceAndComments();
            if (Peek() == '}') { Advance(); break; }   // trailing comma

            std::string key;
            if (!ParseString(key)) { return FailBool("expected a quoted member name"); }
            if (!Expect(':', "expected ':' after the member name")) { return false; }

            JsonValue value;
            if (!ParseValue(value, depth + 1)) { return false; }
            object[std::move(key)] = std::move(value);

            SkipWhitespaceAndComments();
            const char c = Peek();
            if (c == ',') { Advance(); continue; }
            if (c == '}') { Advance(); break; }
            return FailBool("expected ',' or '}'");
        }

        out = JsonValue(std::move(object));
        return true;
    }

    bool ParseArray(JsonValue& out, int depth)
    {
        if (!Expect('[', "expected '['")) { return false; }

        JsonArray array;
        SkipWhitespaceAndComments();
        if (Peek() == ']') { Advance(); out = JsonValue(std::move(array)); return true; }

        for (;;)
        {
            SkipWhitespaceAndComments();
            if (Peek() == ']') { Advance(); break; }   // trailing comma

            JsonValue element;
            if (!ParseValue(element, depth + 1)) { return false; }
            array.push_back(std::move(element));

            SkipWhitespaceAndComments();
            const char c = Peek();
            if (c == ',') { Advance(); continue; }
            if (c == ']') { Advance(); break; }
            return FailBool("expected ',' or ']'");
        }

        out = JsonValue(std::move(array));
        return true;
    }

    bool ParseString(std::string& out)
    {
        SkipWhitespaceAndComments();
        if (Peek() != '"') { return FailBool("expected '\"'"); }
        Advance();

        std::string result;
        for (;;)
        {
            if (AtEnd()) { return FailBool("unterminated string"); }
            const char c = Advance();
            if (c == '"') { break; }
            if (c != '\\') { result.push_back(c); continue; }

            if (AtEnd()) { return FailBool("unterminated escape sequence"); }
            const char esc = Advance();
            switch (esc)
            {
                case '"':  result.push_back('"');  break;
                case '\\': result.push_back('\\'); break;
                case '/':  result.push_back('/');  break;
                case 'b':  result.push_back('\b'); break;
                case 'f':  result.push_back('\f'); break;
                case 'n':  result.push_back('\n'); break;
                case 'r':  result.push_back('\r'); break;
                case 't':  result.push_back('\t'); break;
                case 'u':
                {
                    unsigned int code = 0;
                    for (int i = 0; i < 4; ++i)
                    {
                        if (AtEnd()) { return FailBool("truncated \\u escape"); }
                        const char h = Advance();
                        code <<= 4;
                        if      (h >= '0' && h <= '9') { code |= static_cast<unsigned>(h - '0'); }
                        else if (h >= 'a' && h <= 'f') { code |= static_cast<unsigned>(h - 'a' + 10); }
                        else if (h >= 'A' && h <= 'F') { code |= static_cast<unsigned>(h - 'A' + 10); }
                        else { return FailBool("invalid hex digit in \\u escape"); }
                    }
                    // UTF-8 encode. Surrogate pairs are not expected in these
                    // data files; a lone surrogate is passed through as-is.
                    if (code < 0x80)
                    {
                        result.push_back(static_cast<char>(code));
                    }
                    else if (code < 0x800)
                    {
                        result.push_back(static_cast<char>(0xC0 | (code >> 6)));
                        result.push_back(static_cast<char>(0x80 | (code & 0x3F)));
                    }
                    else
                    {
                        result.push_back(static_cast<char>(0xE0 | (code >> 12)));
                        result.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
                        result.push_back(static_cast<char>(0x80 | (code & 0x3F)));
                    }
                    break;
                }
                default: return FailBool("unknown escape sequence");
            }
        }

        out = std::move(result);
        return true;
    }

    bool ParseNumber(JsonValue& out)
    {
        SkipWhitespaceAndComments();
        const size_t start = Cursor;

        if (Peek() == '-' || Peek() == '+') { Advance(); }
        bool sawDigit = false;
        while (!AtEnd() && Peek() >= '0' && Peek() <= '9') { Advance(); sawDigit = true; }
        if (Peek() == '.')
        {
            Advance();
            while (!AtEnd() && Peek() >= '0' && Peek() <= '9') { Advance(); sawDigit = true; }
        }
        if (!sawDigit) { return FailBool("expected a number"); }

        if (Peek() == 'e' || Peek() == 'E')
        {
            Advance();
            if (Peek() == '-' || Peek() == '+') { Advance(); }
            bool sawExponentDigit = false;
            while (!AtEnd() && Peek() >= '0' && Peek() <= '9') { Advance(); sawExponentDigit = true; }
            if (!sawExponentDigit) { return FailBool("malformed exponent"); }
        }

        const std::string token = Text.substr(start, Cursor - start);
        out = JsonValue(static_cast<Real>(std::strtod(token.c_str(), nullptr)));
        return true;
    }

    const std::string& Text;
    JsonParseResult&   Result;
    size_t Cursor = 0;
    int    Line   = 1;
    int    Column = 1;
};
} // namespace

JsonValue ParseJson(const std::string& text, JsonParseResult& outResult)
{
    outResult = JsonParseResult{};
    Parser parser(text, outResult);
    return parser.Run();
}

bool ReadTextFile(const std::string& path, std::string& outText, std::string& outError)
{
    std::ifstream file(path, std::ios::binary);
    if (!file)
    {
        outError = "cannot open '" + path + "'";
        return false;
    }
    std::ostringstream buffer;
    buffer << file.rdbuf();
    outText = buffer.str();
    return true;
}

JsonValue ParseJsonFile(const std::string& path, JsonParseResult& outResult)
{
    std::string text;
    std::string error;
    if (!ReadTextFile(path, text, error))
    {
        outResult = JsonParseResult{};
        outResult.Success = false;
        outResult.Error   = error;
        outResult.Line    = 0;
        outResult.Column  = 0;
        return JsonValue();
    }
    return ParseJson(text, outResult);
}

} // namespace rc
