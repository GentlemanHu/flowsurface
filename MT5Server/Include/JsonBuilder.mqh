//+------------------------------------------------------------------+
//|                                                  JsonBuilder.mqh |
//|                                     Flowsurface MT5 Data Bridge  |
//|                              High-performance JSON serialization |
//+------------------------------------------------------------------+
#property copyright "Flowsurface"
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| JSON Builder - Efficient JSON string construction                |
//+------------------------------------------------------------------+
class CJsonBuilder
{
private:
    string m_buffer;
    int    m_depth;
    bool   m_first_element[16]; // Track first element at each depth level
    
public:
    CJsonBuilder() : m_depth(0) { Reset(); }
    
    void Reset()
    {
        m_buffer = "";
        m_depth = 0;
        ArrayInitialize(m_first_element, true);
    }
    
    string ToString() { return m_buffer; }
    
    //--- Object/Array control
    void StartObject()
    {
        AddCommaIfNeeded();
        m_buffer += "{";
        m_depth++;
        if(m_depth < 16) m_first_element[m_depth] = true;
    }
    
    void EndObject()
    {
        m_buffer += "}";
        if(m_depth > 0) m_depth--;
    }
    
    void StartArray()
    {
        AddCommaIfNeeded();
        m_buffer += "[";
        m_depth++;
        if(m_depth < 16) m_first_element[m_depth] = true;
    }
    
    void EndArray()
    {
        m_buffer += "]";
        if(m_depth > 0) m_depth--;
    }
    
    //--- Key-Value pairs
    void AddKey(const string key)
    {
        AddCommaIfNeeded();
        m_buffer += "\"" + key + "\":";
        if(m_depth < 16) m_first_element[m_depth] = true; // Next value doesn't need comma
    }
    
    void AddString(const string value)
    {
        AddCommaIfNeeded();
        m_buffer += "\"" + EscapeString(value) + "\"";
    }
    
    void AddInt(const long value)
    {
        AddCommaIfNeeded();
        m_buffer += IntegerToString(value);
    }
    
    void AddDouble(const double value, const int digits = 8)
    {
        AddCommaIfNeeded();
        m_buffer += DoubleToString(value, digits);
    }
    
    void AddBool(const bool value)
    {
        AddCommaIfNeeded();
        m_buffer += value ? "true" : "false";
    }
    
    void AddNull()
    {
        AddCommaIfNeeded();
        m_buffer += "null";
    }
    
    //--- Convenience methods for key:value pairs
    void AddKeyValue(const string key, const string value)
    {
        AddKey(key);
        AddString(value);
    }
    
    void AddKeyValue(const string key, const long value)
    {
        AddKey(key);
        AddInt(value);
    }
    
    void AddKeyValue(const string key, const double value, const int digits = 8)
    {
        AddKey(key);
        AddDouble(value, digits);
    }
    
    void AddKeyValue(const string key, const bool value)
    {
        AddKey(key);
        AddBool(value);
    }
    
    void AddKeyArray(const string key)
    {
        AddKey(key);
        StartArray();
    }
    
    void AddKeyObject(const string key)
    {
        AddKey(key);
        StartObject();
    }

private:
    void AddCommaIfNeeded()
    {
        if(m_depth > 0 && m_depth < 16)
        {
            if(!m_first_element[m_depth])
                m_buffer += ",";
            else
                m_first_element[m_depth] = false;
        }
    }
    
    string EscapeString(const string input)
    {
        string result = input;
        StringReplace(result, "\\", "\\\\");
        StringReplace(result, "\"", "\\\"");
        StringReplace(result, "\n", "\\n");
        StringReplace(result, "\r", "\\r");
        StringReplace(result, "\t", "\\t");
        return result;
    }
};

//+------------------------------------------------------------------+
//| JSON Parser - Basic JSON parsing                                  |
//+------------------------------------------------------------------+
class CJsonParser
{
private:
    string m_json;
    int    m_pos;
    int    m_len;
    
public:
    CJsonParser() : m_pos(0), m_len(0) {}
    
    bool Parse(const string json)
    {
        m_json = json;
        m_pos = 0;
        m_len = StringLen(json);
        return m_len > 0;
    }
    
    bool GetString(const string key, string &value)
    {
        int keyPos = FindKey(key);
        if(keyPos < 0) return false;
        
        int start = StringFind(m_json, "\"", keyPos);
        if(start < 0) return false;
        start++;
        
        int end = StringFind(m_json, "\"", start);
        if(end < 0) return false;
        
        value = StringSubstr(m_json, start, end - start);
        return true;
    }
    
    bool GetLong(const string key, long &value)
    {
        int keyPos = FindKey(key);
        if(keyPos < 0) return false;
        
        string numStr = ExtractNumber(keyPos);
        if(numStr == "") return false;
        
        value = StringToInteger(numStr);
        return true;
    }
    
    bool GetDouble(const string key, double &value)
    {
        int keyPos = FindKey(key);
        if(keyPos < 0) return false;
        
        string numStr = ExtractNumber(keyPos);
        if(numStr == "") return false;
        
        value = StringToDouble(numStr);
        return true;
    }
    
    bool GetBool(const string key, bool &value)
    {
        int keyPos = FindKey(key);
        if(keyPos < 0) return false;
        
        if(StringFind(m_json, "true", keyPos) == keyPos)
        {
            value = true;
            return true;
        }
        if(StringFind(m_json, "false", keyPos) == keyPos)
        {
            value = false;
            return true;
        }
        return false;
    }
    
    bool HasKey(const string key)
    {
        return FindKey(key) >= 0;
    }
    
private:
    int FindKey(const string key)
    {
        string searchKey = "\"" + key + "\"";
        int pos = StringFind(m_json, searchKey);
        if(pos < 0) return -1;
        
        // Find the colon after the key
        int colonPos = StringFind(m_json, ":", pos + StringLen(searchKey));
        if(colonPos < 0) return -1;
        
        // Return position after colon (skip whitespace)
        for(int i = colonPos + 1; i < m_len; i++)
        {
            ushort ch = StringGetCharacter(m_json, i);
            if(ch != ' ' && ch != '\t' && ch != '\n' && ch != '\r')
                return i;
        }
        return -1;
    }
    
    string ExtractNumber(int startPos)
    {
        string result = "";
        for(int i = startPos; i < m_len; i++)
        {
            ushort ch = StringGetCharacter(m_json, i);
            if((ch >= '0' && ch <= '9') || ch == '.' || ch == '-' || ch == '+' || ch == 'e' || ch == 'E')
                result += ShortToString(ch);
            else if(StringLen(result) > 0)
                break;
        }
        return result;
    }
};
