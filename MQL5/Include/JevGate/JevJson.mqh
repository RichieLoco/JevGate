//+------------------------------------------------------------------+
//|                                                     JevJson.mqh  |
//|  Minimal JSON reader/writer helpers for JevGate.                 |
//|  Parses RFC 8259 JSON into a small tree. No dependencies.        |
//|  MIT licence.                                                    |
//+------------------------------------------------------------------+
#ifndef JEVJSON_MQH
#define JEVJSON_MQH

enum ENUM_JEVJSON_TYPE
  {
   JEVJSON_NULL = 0,
   JEVJSON_BOOL,
   JEVJSON_NUMBER,
   JEVJSON_STRING,
   JEVJSON_ARRAY,
   JEVJSON_OBJECT
  };

//+------------------------------------------------------------------+
//| A JSON value. Objects keep keys in m_keys[] parallel to m_items[]|
//| Arrays use m_items[] only. The node owns its children.           |
//+------------------------------------------------------------------+
class CJevJson
  {
public:
   ENUM_JEVJSON_TYPE kind;
   string            str;
   double            num;
   bool              flag;
   string            m_keys[];
   CJevJson         *m_items[];

                     CJevJson(void) : kind(JEVJSON_NULL), str(""), num(0.0), flag(false) {}
                    ~CJevJson(void)
     {
      for(int i = 0; i < ArraySize(m_items); i++)
         if(CheckPointer(m_items[i]) == POINTER_DYNAMIC)
            delete m_items[i];
     }

   int               Size(void) const { return ArraySize(m_items); }
   CJevJson         *At(const int i)  { return (i >= 0 && i < ArraySize(m_items)) ? m_items[i] : NULL; }
   string            KeyAt(const int i) const { return (i >= 0 && i < ArraySize(m_keys)) ? m_keys[i] : ""; }

   CJevJson         *Get(const string key)
     {
      if(kind != JEVJSON_OBJECT)
         return NULL;
      for(int i = 0; i < ArraySize(m_keys); i++)
         if(m_keys[i] == key)
            return m_items[i];
      return NULL;
     }

   bool              IsNumber(void) const { return kind == JEVJSON_NUMBER; }
   bool              IsString(void) const { return kind == JEVJSON_STRING; }
   bool              IsObject(void) const { return kind == JEVJSON_OBJECT; }

   double            AsNumber(const double dflt = 0.0) const
     {
      if(kind == JEVJSON_NUMBER) return num;
      if(kind == JEVJSON_BOOL)   return flag ? 1.0 : 0.0;
      if(kind == JEVJSON_STRING) return StringToDouble(str);
      return dflt;
     }

   string            AsString(const string dflt = "") const
     {
      if(kind == JEVJSON_STRING) return str;
      if(kind == JEVJSON_NUMBER) return DoubleToString(num,8);
      if(kind == JEVJSON_BOOL)   return flag ? "true" : "false";
      return dflt;
     }

   void              Append(const string key,CJevJson *child)
     {
      int n = ArraySize(m_items);
      ArrayResize(m_items,n + 1);
      ArrayResize(m_keys,n + 1);
      m_items[n] = child;
      m_keys[n]  = key;
     }
  };

//+------------------------------------------------------------------+
//| Recursive-descent parser                                         |
//+------------------------------------------------------------------+
class CJevJsonParser
  {
private:
   string            m_s;
   int               m_pos;
   int               m_len;
   int               m_depth;
   string            m_err;

   ushort            Ch(const int i) const { return (i < m_len) ? StringGetCharacter(m_s,i) : 0; }

   void              SkipWs(void)
     {
      while(m_pos < m_len)
        {
         ushort c = Ch(m_pos);
         if(c == ' ' || c == '\t' || c == '\r' || c == '\n')
            m_pos++;
         else
            break;
        }
     }

   CJevJson         *Fail(const string why)
     {
      if(m_err == "")
         m_err = StringFormat("%s at position %d",why,m_pos);
      return NULL;
     }

   static int        HexVal(const ushort c)
     {
      if(c >= '0' && c <= '9') return c - '0';
      if(c >= 'a' && c <= 'f') return c - 'a' + 10;
      if(c >= 'A' && c <= 'F') return c - 'A' + 10;
      return -1;
     }

   bool              ParseString(string &out)
     {
      // assumes Ch(m_pos) == '"'
      m_pos++;
      out = "";
      int runStart = m_pos;
      while(m_pos < m_len)
        {
         ushort c = Ch(m_pos);
         if(c == '"')
           {
            out += StringSubstr(m_s,runStart,m_pos - runStart);
            m_pos++;
            return true;
           }
         if(c == '\\')
           {
            out += StringSubstr(m_s,runStart,m_pos - runStart);
            m_pos++;
            ushort e = Ch(m_pos);
            switch(e)
              {
               case '"':  out += "\"";  break;
               case '\\': out += "\\";  break;
               case '/':  out += "/";   break;
               case 'b':  out += ShortToString(8);  break;
               case 'f':  out += ShortToString(12); break;
               case 'n':  out += "\n";  break;
               case 'r':  out += "\r";  break;
               case 't':  out += "\t";  break;
               case 'u':
                 {
                  int code = 0;
                  for(int k = 1; k <= 4; k++)
                    {
                     int h = HexVal(Ch(m_pos + k));
                     if(h < 0)
                       {
                        Fail("bad \\u escape");
                        return false;
                       }
                     code = code * 16 + h;
                    }
                  out += ShortToString((ushort)code);
                  m_pos += 4;
                  break;
                 }
               default:
                  Fail("bad escape");
                  return false;
              }
            m_pos++;
            runStart = m_pos;
            continue;
           }
         m_pos++;
        }
      Fail("unterminated string");
      return false;
     }

   CJevJson         *ParseNumber(void)
     {
      int start = m_pos;
      while(m_pos < m_len)
        {
         ushort c = Ch(m_pos);
         if((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E')
            m_pos++;
         else
            break;
        }
      string tok = StringSubstr(m_s,start,m_pos - start);
      if(tok == "" || tok == "-")
         return Fail("bad number");
      double v;
      int e = StringFind(tok,"e");
      if(e < 0)
         e = StringFind(tok,"E");
      if(e >= 0)
        {
         string ex = StringSubstr(tok,e + 1);
         if(StringGetCharacter(ex,0) == '+')
            ex = StringSubstr(ex,1);
         v = StringToDouble(StringSubstr(tok,0,e)) * MathPow(10.0,(double)StringToInteger(ex));
        }
      else
         v = StringToDouble(tok);
      CJevJson *n = new CJevJson();
      n.kind = JEVJSON_NUMBER;
      n.num  = v;
      return n;
     }

   CJevJson         *ParseLiteral(const string word,const ENUM_JEVJSON_TYPE t,const bool val)
     {
      if(StringSubstr(m_s,m_pos,StringLen(word)) != word)
         return Fail("unexpected token");
      m_pos += StringLen(word);
      CJevJson *n = new CJevJson();
      n.kind = t;
      n.flag = val;
      return n;
     }

   CJevJson         *ParseArray(void)
     {
      m_pos++; // [
      CJevJson *arr = new CJevJson();
      arr.kind = JEVJSON_ARRAY;
      SkipWs();
      if(Ch(m_pos) == ']')
        {
         m_pos++;
         return arr;
        }
      while(true)
        {
         CJevJson *item = ParseValue();
         if(item == NULL)
           {
            delete arr;
            return NULL;
           }
         arr.Append("",item);
         SkipWs();
         ushort c = Ch(m_pos);
         if(c == ',')
           {
            m_pos++;
            continue;
           }
         if(c == ']')
           {
            m_pos++;
            return arr;
           }
         delete arr;
         return Fail("expected , or ]");
        }
      return NULL;
     }

   CJevJson         *ParseObject(void)
     {
      m_pos++; // {
      CJevJson *obj = new CJevJson();
      obj.kind = JEVJSON_OBJECT;
      SkipWs();
      if(Ch(m_pos) == '}')
        {
         m_pos++;
         return obj;
        }
      while(true)
        {
         SkipWs();
         if(Ch(m_pos) != '"')
           {
            delete obj;
            return Fail("expected key");
           }
         string key;
         if(!ParseString(key))
           {
            delete obj;
            return NULL;
           }
         SkipWs();
         if(Ch(m_pos) != ':')
           {
            delete obj;
            return Fail("expected :");
           }
         m_pos++;
         CJevJson *val = ParseValue();
         if(val == NULL)
           {
            delete obj;
            return NULL;
           }
         obj.Append(key,val);
         SkipWs();
         ushort c = Ch(m_pos);
         if(c == ',')
           {
            m_pos++;
            continue;
           }
         if(c == '}')
           {
            m_pos++;
            return obj;
           }
         delete obj;
         return Fail("expected , or }");
        }
      return NULL;
     }

   CJevJson         *ParseValue(void)
     {
      if(++m_depth > 64)
         return Fail("nesting too deep");
      SkipWs();
      CJevJson *r = NULL;
      ushort c = Ch(m_pos);
      if(c == '{')
         r = ParseObject();
      else if(c == '[')
         r = ParseArray();
      else if(c == '"')
        {
         string s;
         if(ParseString(s))
           {
            r = new CJevJson();
            r.kind = JEVJSON_STRING;
            r.str  = s;
           }
        }
      else if(c == 't')
         r = ParseLiteral("true",JEVJSON_BOOL,true);
      else if(c == 'f')
         r = ParseLiteral("false",JEVJSON_BOOL,false);
      else if(c == 'n')
         r = ParseLiteral("null",JEVJSON_NULL,false);
      else if(c == '-' || (c >= '0' && c <= '9'))
         r = ParseNumber();
      else
         r = Fail(c == 0 ? "unexpected end of input" : "unexpected character");
      m_depth--;
      return r;
     }

public:
   //--- returns a tree the caller must delete, or NULL (see Error())
   CJevJson         *Parse(const string text)
     {
      m_s     = text;
      m_len   = StringLen(text);
      m_pos   = 0;
      m_depth = 0;
      m_err   = "";
      CJevJson *root = ParseValue();
      if(root == NULL)
         return NULL;
      SkipWs();
      if(m_pos < m_len)
        {
         delete root;
         Fail("trailing characters");
         return NULL;
        }
      return root;
     }

   string            Error(void) const { return m_err; }
  };

//+------------------------------------------------------------------+
//| Escape a string for inclusion in a JSON document                 |
//+------------------------------------------------------------------+
string JevJsonEscape(const string s)
  {
   string r = s;
   StringReplace(r,"\\","\\\\");
   StringReplace(r,"\"","\\\"");
   StringReplace(r,"\n","\\n");
   StringReplace(r,"\r","\\r");
   StringReplace(r,"\t","\\t");
   return r;
  }

#endif // JEVJSON_MQH
//+------------------------------------------------------------------+
