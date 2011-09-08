class Hummus::Parser
# STANDALONE START
    def setup_parser(str, debug=false)
      @string = str
      @pos = 0
      @memoizations = Hash.new { |h,k| h[k] = {} }
      @result = nil
      @failed_rule = nil
      @failing_rule_offset = -1

      setup_foreign_grammar
    end

    # This is distinct from setup_parser so that a standalone parser
    # can redefine #initialize and still have access to the proper
    # parser setup code.
    #
    def initialize(str, debug=false)
      setup_parser(str, debug)
    end

    attr_reader :string
    attr_reader :failing_rule_offset
    attr_accessor :result, :pos

    # STANDALONE START
    def current_column(target=pos)
      if c = string.rindex("\n", target-1)
        return target - c - 1
      end

      target + 1
    end

    def current_line(target=pos)
      cur_offset = 0
      cur_line = 0

      string.each_line do |line|
        cur_line += 1
        cur_offset += line.size
        return cur_line if cur_offset >= target
      end

      -1
    end

    def lines
      lines = []
      string.each_line { |l| lines << l }
      lines
    end

    #

    def get_text(start)
      @string[start..@pos-1]
    end

    def show_pos
      width = 10
      if @pos < width
        "#{@pos} (\"#{@string[0,@pos]}\" @ \"#{@string[@pos,width]}\")"
      else
        "#{@pos} (\"... #{@string[@pos - width, width]}\" @ \"#{@string[@pos,width]}\")"
      end
    end

    def failure_info
      l = current_line @failing_rule_offset
      c = current_column @failing_rule_offset

      if @failed_rule.kind_of? Symbol
        info = self.class::Rules[@failed_rule]
        "line #{l}, column #{c}: failed rule '#{info.name}' = '#{info.rendered}'"
      else
        "line #{l}, column #{c}: failed rule '#{@failed_rule}'"
      end
    end

    def failure_caret
      l = current_line @failing_rule_offset
      c = current_column @failing_rule_offset

      line = lines[l-1]
      "#{line}\n#{' ' * (c - 1)}^"
    end

    def failure_character
      l = current_line @failing_rule_offset
      c = current_column @failing_rule_offset
      lines[l-1][c-1, 1]
    end

    def failure_oneline
      l = current_line @failing_rule_offset
      c = current_column @failing_rule_offset

      char = lines[l-1][c-1, 1]

      if @failed_rule.kind_of? Symbol
        info = self.class::Rules[@failed_rule]
        "@#{l}:#{c} failed rule '#{info.name}', got '#{char}'"
      else
        "@#{l}:#{c} failed rule '#{@failed_rule}', got '#{char}'"
      end
    end

    class ParseError < RuntimeError
    end

    def raise_error
      raise ParseError, failure_oneline
    end

    def show_error(io=STDOUT)
      error_pos = @failing_rule_offset
      line_no = current_line(error_pos)
      col_no = current_column(error_pos)

      io.puts "On line #{line_no}, column #{col_no}:"

      if @failed_rule.kind_of? Symbol
        info = self.class::Rules[@failed_rule]
        io.puts "Failed to match '#{info.rendered}' (rule '#{info.name}')"
      else
        io.puts "Failed to match rule '#{@failed_rule}'"
      end

      io.puts "Got: #{string[error_pos,1].inspect}"
      line = lines[line_no-1]
      io.puts "=> #{line}"
      io.print(" " * (col_no + 3))
      io.puts "^"
    end

    def set_failed_rule(name)
      if @pos > @failing_rule_offset
        @failed_rule = name
        @failing_rule_offset = @pos
      end
    end

    attr_reader :failed_rule

    def match_string(str)
      len = str.size
      if @string[pos,len] == str
        @pos += len
        return str
      end

      return nil
    end

    def scan(reg)
      if m = reg.match(@string[@pos..-1])
        width = m.end(0)
        @pos += width
        return true
      end

      return nil
    end

    if "".respond_to? :getbyte
      def get_byte
        if @pos >= @string.size
          return nil
        end

        s = @string.getbyte @pos
        @pos += 1
        s
      end
    else
      def get_byte
        if @pos >= @string.size
          return nil
        end

        s = @string[@pos]
        @pos += 1
        s
      end
    end

    def parse(rule=nil)
      if !rule
        _root ? true : false
      else
        # This is not shared with code_generator.rb so this can be standalone
        method = rule.gsub("-","_hyphen_")
        __send__("_#{method}") ? true : false
      end
    end

    class LeftRecursive
      def initialize(detected=false)
        @detected = detected
      end

      attr_accessor :detected
    end

    class MemoEntry
      def initialize(ans, pos)
        @ans = ans
        @pos = pos
        @uses = 1
        @result = nil
      end

      attr_reader :ans, :pos, :uses, :result

      def inc!
        @uses += 1
      end

      def move!(ans, pos, result)
        @ans = ans
        @pos = pos
        @result = result
      end
    end

    def external_invoke(other, rule, *args)
      old_pos = @pos
      old_string = @string

      @pos = other.pos
      @string = other.string

      begin
        if val = __send__(rule, *args)
          other.pos = @pos
          other.result = @result
        else
          other.set_failed_rule "#{self.class}##{rule}"
        end
        val
      ensure
        @pos = old_pos
        @string = old_string
      end
    end

    def apply_with_args(rule, *args)
      memo_key = [rule, args]
      if m = @memoizations[memo_key][@pos]
        m.inc!

        prev = @pos
        @pos = m.pos
        if m.ans.kind_of? LeftRecursive
          m.ans.detected = true
          return nil
        end

        @result = m.result

        return m.ans
      else
        lr = LeftRecursive.new(false)
        m = MemoEntry.new(lr, @pos)
        @memoizations[memo_key][@pos] = m
        start_pos = @pos

        ans = __send__ rule, *args

        m.move! ans, @pos, @result

        # Don't bother trying to grow the left recursion
        # if it's failing straight away (thus there is no seed)
        if ans and lr.detected
          return grow_lr(rule, args, start_pos, m)
        else
          return ans
        end

        return ans
      end
    end

    def apply(rule)
      if m = @memoizations[rule][@pos]
        m.inc!

        prev = @pos
        @pos = m.pos
        if m.ans.kind_of? LeftRecursive
          m.ans.detected = true
          return nil
        end

        @result = m.result

        return m.ans
      else
        lr = LeftRecursive.new(false)
        m = MemoEntry.new(lr, @pos)
        @memoizations[rule][@pos] = m
        start_pos = @pos

        ans = __send__ rule

        m.move! ans, @pos, @result

        # Don't bother trying to grow the left recursion
        # if it's failing straight away (thus there is no seed)
        if ans and lr.detected
          return grow_lr(rule, nil, start_pos, m)
        else
          return ans
        end

        return ans
      end
    end

    def grow_lr(rule, args, start_pos, m)
      while true
        @pos = start_pos
        @result = m.result

        if args
          ans = __send__ rule, *args
        else
          ans = __send__ rule
        end
        return nil unless ans

        break if @pos <= m.pos

        m.move! ans, @pos, @result
      end

      @result = m.result
      @pos = m.pos
      return m.ans
    end

    class RuleInfo
      def initialize(name, rendered)
        @name = name
        @rendered = rendered
      end

      attr_reader :name, :rendered
    end

    def self.rule_info(name, rendered)
      RuleInfo.new(name, rendered)
    end

    #
  def setup_foreign_grammar; end

  # - = (comment | /\s/)*
  def __hyphen_
    while true

      _save1 = self.pos
      while true # choice
        _tmp = apply(:_comment)
        break if _tmp
        self.pos = _save1
        _tmp = scan(/\A(?-mix:\s)/)
        break if _tmp
        self.pos = _save1
        break
      end # end choice

      break unless _tmp
    end
    _tmp = true
    set_failed_rule :__hyphen_ unless _tmp
    return _tmp
  end

  # identifier = < /[\p{L}\p{S}\d!@#%&*\-\\:.\/\?_]+/u > { text }
  def _identifier

    _save = self.pos
    while true # sequence
      _text_start = self.pos
      _tmp = scan(/\A(?-mix:[\p{L}\p{S}\d!@#%&*\-\\:.\/\?_]+)/u)
      if _tmp
        text = get_text(_text_start)
      end
      unless _tmp
        self.pos = _save
        break
      end
      @result = begin;  text ; end
      _tmp = true
      unless _tmp
        self.pos = _save
      end
      break
    end # end sequence

    set_failed_rule :_identifier unless _tmp
    return _tmp
  end

  # comment = /;.*?$/
  def _comment
    _tmp = scan(/\A(?-mix:;.*?$)/)
    set_failed_rule :_comment unless _tmp
    return _tmp
  end

  # expression = (number | string | constant | symbol | list)
  def _expression

    _save = self.pos
    while true # choice
      _tmp = apply(:_number)
      break if _tmp
      self.pos = _save
      _tmp = apply(:_string)
      break if _tmp
      self.pos = _save
      _tmp = apply(:_constant)
      break if _tmp
      self.pos = _save
      _tmp = apply(:_symbol)
      break if _tmp
      self.pos = _save
      _tmp = apply(:_list)
      break if _tmp
      self.pos = _save
      break
    end # end choice

    set_failed_rule :_expression unless _tmp
    return _tmp
  end

  # number = (< /[\+\-]?0[oO][0-7]+/ > { Hummus::Number.new(text.to_i(8)) } | < /[\+\-]?0[xX][\da-fA-F]+/ > { Hummus::Number.new(text.to_i(16)) } | < /[\+\-]?\d+(\.\d+)?[eE][\+\-]?\d+/ > { Hummus::Number.new(text.to_f) } | < /[\+\-]?\d+\.\d+/ > { Hummus::Number.new(text.to_f) } | < /[\+\-]?\d+/ > { Hummus::Number.new(text.to_i) })
  def _number

    _save = self.pos
    while true # choice

      _save1 = self.pos
      while true # sequence
        _text_start = self.pos
        _tmp = scan(/\A(?-mix:[\+\-]?0[oO][0-7]+)/)
        if _tmp
          text = get_text(_text_start)
        end
        unless _tmp
          self.pos = _save1
          break
        end
        @result = begin;  Hummus::Number.new(text.to_i(8)) ; end
        _tmp = true
        unless _tmp
          self.pos = _save1
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save2 = self.pos
      while true # sequence
        _text_start = self.pos
        _tmp = scan(/\A(?-mix:[\+\-]?0[xX][\da-fA-F]+)/)
        if _tmp
          text = get_text(_text_start)
        end
        unless _tmp
          self.pos = _save2
          break
        end
        @result = begin;  Hummus::Number.new(text.to_i(16)) ; end
        _tmp = true
        unless _tmp
          self.pos = _save2
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save3 = self.pos
      while true # sequence
        _text_start = self.pos
        _tmp = scan(/\A(?-mix:[\+\-]?\d+(\.\d+)?[eE][\+\-]?\d+)/)
        if _tmp
          text = get_text(_text_start)
        end
        unless _tmp
          self.pos = _save3
          break
        end
        @result = begin;  Hummus::Number.new(text.to_f) ; end
        _tmp = true
        unless _tmp
          self.pos = _save3
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save4 = self.pos
      while true # sequence
        _text_start = self.pos
        _tmp = scan(/\A(?-mix:[\+\-]?\d+\.\d+)/)
        if _tmp
          text = get_text(_text_start)
        end
        unless _tmp
          self.pos = _save4
          break
        end
        @result = begin;  Hummus::Number.new(text.to_f) ; end
        _tmp = true
        unless _tmp
          self.pos = _save4
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save5 = self.pos
      while true # sequence
        _text_start = self.pos
        _tmp = scan(/\A(?-mix:[\+\-]?\d+)/)
        if _tmp
          text = get_text(_text_start)
        end
        unless _tmp
          self.pos = _save5
          break
        end
        @result = begin;  Hummus::Number.new(text.to_i) ; end
        _tmp = true
        unless _tmp
          self.pos = _save5
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save
      break
    end # end choice

    set_failed_rule :_number unless _tmp
    return _tmp
  end

  # escape = (number_escapes | escapes)
  def _escape

    _save = self.pos
    while true # choice
      _tmp = apply(:_number_escapes)
      break if _tmp
      self.pos = _save
      _tmp = apply(:_escapes)
      break if _tmp
      self.pos = _save
      break
    end # end choice

    set_failed_rule :_escape unless _tmp
    return _tmp
  end

  # str_seq = < /[^\\"]+/ > { text }
  def _str_seq

    _save = self.pos
    while true # sequence
      _text_start = self.pos
      _tmp = scan(/\A(?-mix:[^\\"]+)/)
      if _tmp
        text = get_text(_text_start)
      end
      unless _tmp
        self.pos = _save
        break
      end
      @result = begin;  text ; end
      _tmp = true
      unless _tmp
        self.pos = _save
      end
      break
    end # end sequence

    set_failed_rule :_str_seq unless _tmp
    return _tmp
  end

  # string = "\"" < ("\\" escape | str_seq)*:c > "\"" { Hummus::String.new(text.gsub("\\\"", "\"")) }
  def _string

    _save = self.pos
    while true # sequence
      _tmp = match_string("\"")
      unless _tmp
        self.pos = _save
        break
      end
      _text_start = self.pos
      _ary = []
      while true

        _save2 = self.pos
        while true # choice

          _save3 = self.pos
          while true # sequence
            _tmp = match_string("\\")
            unless _tmp
              self.pos = _save3
              break
            end
            _tmp = apply(:_escape)
            unless _tmp
              self.pos = _save3
            end
            break
          end # end sequence

          break if _tmp
          self.pos = _save2
          _tmp = apply(:_str_seq)
          break if _tmp
          self.pos = _save2
          break
        end # end choice

        _ary << @result if _tmp
        break unless _tmp
      end
      _tmp = true
      @result = _ary
      c = @result
      if _tmp
        text = get_text(_text_start)
      end
      unless _tmp
        self.pos = _save
        break
      end
      _tmp = match_string("\"")
      unless _tmp
        self.pos = _save
        break
      end
      @result = begin;  Hummus::String.new(text.gsub("\\\"", "\"")) ; end
      _tmp = true
      unless _tmp
        self.pos = _save
      end
      break
    end # end sequence

    set_failed_rule :_string unless _tmp
    return _tmp
  end

  # symbol = identifier:n { Hummus::Symbol.new(n.to_sym) }
  def _symbol

    _save = self.pos
    while true # sequence
      _tmp = apply(:_identifier)
      n = @result
      unless _tmp
        self.pos = _save
        break
      end
      @result = begin;  Hummus::Symbol.new(n.to_sym) ; end
      _tmp = true
      unless _tmp
        self.pos = _save
      end
      break
    end # end sequence

    set_failed_rule :_symbol unless _tmp
    return _tmp
  end

  # constant = ("#t" { Hummus::True } | "#f" { Hummus::False } | "#ignore" { Hummus::Ignore } | "#inert" { Hummus::Inert })
  def _constant

    _save = self.pos
    while true # choice

      _save1 = self.pos
      while true # sequence
        _tmp = match_string("#t")
        unless _tmp
          self.pos = _save1
          break
        end
        @result = begin;  Hummus::True ; end
        _tmp = true
        unless _tmp
          self.pos = _save1
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save2 = self.pos
      while true # sequence
        _tmp = match_string("#f")
        unless _tmp
          self.pos = _save2
          break
        end
        @result = begin;  Hummus::False ; end
        _tmp = true
        unless _tmp
          self.pos = _save2
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save3 = self.pos
      while true # sequence
        _tmp = match_string("#ignore")
        unless _tmp
          self.pos = _save3
          break
        end
        @result = begin;  Hummus::Ignore ; end
        _tmp = true
        unless _tmp
          self.pos = _save3
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save4 = self.pos
      while true # sequence
        _tmp = match_string("#inert")
        unless _tmp
          self.pos = _save4
          break
        end
        @result = begin;  Hummus::Inert ; end
        _tmp = true
        unless _tmp
          self.pos = _save4
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save
      break
    end # end choice

    set_failed_rule :_constant unless _tmp
    return _tmp
  end

  # list = "(" - pairs:ps - ")" { ps }
  def _list

    _save = self.pos
    while true # sequence
      _tmp = match_string("(")
      unless _tmp
        self.pos = _save
        break
      end
      _tmp = apply(:__hyphen_)
      unless _tmp
        self.pos = _save
        break
      end
      _tmp = apply(:_pairs)
      ps = @result
      unless _tmp
        self.pos = _save
        break
      end
      _tmp = apply(:__hyphen_)
      unless _tmp
        self.pos = _save
        break
      end
      _tmp = match_string(")")
      unless _tmp
        self.pos = _save
        break
      end
      @result = begin;  ps ; end
      _tmp = true
      unless _tmp
        self.pos = _save
      end
      break
    end # end sequence

    set_failed_rule :_list unless _tmp
    return _tmp
  end

  # pairs = (expression:a - "." - expression:b { Hummus::Pair.new(a, b) } | pairs:a - "." - expression:b { Hummus::Pair.new(a, b) } | expression:a - pairs:b { Hummus::Pair.new(a, b) } | expression:a { Hummus::Pair.new(a, Hummus::Null.new) } | { Hummus::Null.new })
  def _pairs

    _save = self.pos
    while true # choice

      _save1 = self.pos
      while true # sequence
        _tmp = apply(:_expression)
        a = @result
        unless _tmp
          self.pos = _save1
          break
        end
        _tmp = apply(:__hyphen_)
        unless _tmp
          self.pos = _save1
          break
        end
        _tmp = match_string(".")
        unless _tmp
          self.pos = _save1
          break
        end
        _tmp = apply(:__hyphen_)
        unless _tmp
          self.pos = _save1
          break
        end
        _tmp = apply(:_expression)
        b = @result
        unless _tmp
          self.pos = _save1
          break
        end
        @result = begin;  Hummus::Pair.new(a, b) ; end
        _tmp = true
        unless _tmp
          self.pos = _save1
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save2 = self.pos
      while true # sequence
        _tmp = apply(:_pairs)
        a = @result
        unless _tmp
          self.pos = _save2
          break
        end
        _tmp = apply(:__hyphen_)
        unless _tmp
          self.pos = _save2
          break
        end
        _tmp = match_string(".")
        unless _tmp
          self.pos = _save2
          break
        end
        _tmp = apply(:__hyphen_)
        unless _tmp
          self.pos = _save2
          break
        end
        _tmp = apply(:_expression)
        b = @result
        unless _tmp
          self.pos = _save2
          break
        end
        @result = begin;  Hummus::Pair.new(a, b) ; end
        _tmp = true
        unless _tmp
          self.pos = _save2
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save3 = self.pos
      while true # sequence
        _tmp = apply(:_expression)
        a = @result
        unless _tmp
          self.pos = _save3
          break
        end
        _tmp = apply(:__hyphen_)
        unless _tmp
          self.pos = _save3
          break
        end
        _tmp = apply(:_pairs)
        b = @result
        unless _tmp
          self.pos = _save3
          break
        end
        @result = begin;  Hummus::Pair.new(a, b) ; end
        _tmp = true
        unless _tmp
          self.pos = _save3
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save4 = self.pos
      while true # sequence
        _tmp = apply(:_expression)
        a = @result
        unless _tmp
          self.pos = _save4
          break
        end
        @result = begin;  Hummus::Pair.new(a, Hummus::Null.new) ; end
        _tmp = true
        unless _tmp
          self.pos = _save4
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save
      @result = begin;  Hummus::Null.new ; end
      _tmp = true
      break if _tmp
      self.pos = _save
      break
    end # end choice

    set_failed_rule :_pairs unless _tmp
    return _tmp
  end

  # escapes = ("n" { "\n" } | "s" { " " } | "r" { "\r" } | "t" { "\t" } | "v" { "\v" } | "f" { "\f" } | "b" { "\b" } | "a" { "\a" } | "e" { "\e" } | "\\" { "\\" } | "\"" { "\"" } | "BS" { "\b" } | "HT" { "\t" } | "LF" { "\n" } | "VT" { "\v" } | "FF" { "\f" } | "CR" { "\r" } | "SO" { "\016" } | "SI" { "\017" } | "EM" { "\031" } | "FS" { "\034" } | "GS" { "\035" } | "RS" { "\036" } | "US" { "\037" } | "SP" { " " } | "NUL" { "\000" } | "SOH" { "\001" } | "STX" { "\002" } | "ETX" { "\003" } | "EOT" { "\004" } | "ENQ" { "\005" } | "ACK" { "\006" } | "BEL" { "\a" } | "DLE" { "\020" } | "DC1" { "\021" } | "DC2" { "\022" } | "DC3" { "\023" } | "DC4" { "\024" } | "NAK" { "\025" } | "SYN" { "\026" } | "ETB" { "\027" } | "CAN" { "\030" } | "SUB" { "\032" } | "ESC" { "\e" } | "DEL" { "\177" } | < . > { "\\" + text })
  def _escapes

    _save = self.pos
    while true # choice

      _save1 = self.pos
      while true # sequence
        _tmp = match_string("n")
        unless _tmp
          self.pos = _save1
          break
        end
        @result = begin;  "\n" ; end
        _tmp = true
        unless _tmp
          self.pos = _save1
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save2 = self.pos
      while true # sequence
        _tmp = match_string("s")
        unless _tmp
          self.pos = _save2
          break
        end
        @result = begin;  " " ; end
        _tmp = true
        unless _tmp
          self.pos = _save2
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save3 = self.pos
      while true # sequence
        _tmp = match_string("r")
        unless _tmp
          self.pos = _save3
          break
        end
        @result = begin;  "\r" ; end
        _tmp = true
        unless _tmp
          self.pos = _save3
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save4 = self.pos
      while true # sequence
        _tmp = match_string("t")
        unless _tmp
          self.pos = _save4
          break
        end
        @result = begin;  "\t" ; end
        _tmp = true
        unless _tmp
          self.pos = _save4
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save5 = self.pos
      while true # sequence
        _tmp = match_string("v")
        unless _tmp
          self.pos = _save5
          break
        end
        @result = begin;  "\v" ; end
        _tmp = true
        unless _tmp
          self.pos = _save5
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save6 = self.pos
      while true # sequence
        _tmp = match_string("f")
        unless _tmp
          self.pos = _save6
          break
        end
        @result = begin;  "\f" ; end
        _tmp = true
        unless _tmp
          self.pos = _save6
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save7 = self.pos
      while true # sequence
        _tmp = match_string("b")
        unless _tmp
          self.pos = _save7
          break
        end
        @result = begin;  "\b" ; end
        _tmp = true
        unless _tmp
          self.pos = _save7
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save8 = self.pos
      while true # sequence
        _tmp = match_string("a")
        unless _tmp
          self.pos = _save8
          break
        end
        @result = begin;  "\a" ; end
        _tmp = true
        unless _tmp
          self.pos = _save8
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save9 = self.pos
      while true # sequence
        _tmp = match_string("e")
        unless _tmp
          self.pos = _save9
          break
        end
        @result = begin;  "\e" ; end
        _tmp = true
        unless _tmp
          self.pos = _save9
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save10 = self.pos
      while true # sequence
        _tmp = match_string("\\")
        unless _tmp
          self.pos = _save10
          break
        end
        @result = begin;  "\\" ; end
        _tmp = true
        unless _tmp
          self.pos = _save10
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save11 = self.pos
      while true # sequence
        _tmp = match_string("\"")
        unless _tmp
          self.pos = _save11
          break
        end
        @result = begin;  "\"" ; end
        _tmp = true
        unless _tmp
          self.pos = _save11
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save12 = self.pos
      while true # sequence
        _tmp = match_string("BS")
        unless _tmp
          self.pos = _save12
          break
        end
        @result = begin;  "\b" ; end
        _tmp = true
        unless _tmp
          self.pos = _save12
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save13 = self.pos
      while true # sequence
        _tmp = match_string("HT")
        unless _tmp
          self.pos = _save13
          break
        end
        @result = begin;  "\t" ; end
        _tmp = true
        unless _tmp
          self.pos = _save13
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save14 = self.pos
      while true # sequence
        _tmp = match_string("LF")
        unless _tmp
          self.pos = _save14
          break
        end
        @result = begin;  "\n" ; end
        _tmp = true
        unless _tmp
          self.pos = _save14
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save15 = self.pos
      while true # sequence
        _tmp = match_string("VT")
        unless _tmp
          self.pos = _save15
          break
        end
        @result = begin;  "\v" ; end
        _tmp = true
        unless _tmp
          self.pos = _save15
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save16 = self.pos
      while true # sequence
        _tmp = match_string("FF")
        unless _tmp
          self.pos = _save16
          break
        end
        @result = begin;  "\f" ; end
        _tmp = true
        unless _tmp
          self.pos = _save16
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save17 = self.pos
      while true # sequence
        _tmp = match_string("CR")
        unless _tmp
          self.pos = _save17
          break
        end
        @result = begin;  "\r" ; end
        _tmp = true
        unless _tmp
          self.pos = _save17
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save18 = self.pos
      while true # sequence
        _tmp = match_string("SO")
        unless _tmp
          self.pos = _save18
          break
        end
        @result = begin;  "\016" ; end
        _tmp = true
        unless _tmp
          self.pos = _save18
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save19 = self.pos
      while true # sequence
        _tmp = match_string("SI")
        unless _tmp
          self.pos = _save19
          break
        end
        @result = begin;  "\017" ; end
        _tmp = true
        unless _tmp
          self.pos = _save19
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save20 = self.pos
      while true # sequence
        _tmp = match_string("EM")
        unless _tmp
          self.pos = _save20
          break
        end
        @result = begin;  "\031" ; end
        _tmp = true
        unless _tmp
          self.pos = _save20
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save21 = self.pos
      while true # sequence
        _tmp = match_string("FS")
        unless _tmp
          self.pos = _save21
          break
        end
        @result = begin;  "\034" ; end
        _tmp = true
        unless _tmp
          self.pos = _save21
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save22 = self.pos
      while true # sequence
        _tmp = match_string("GS")
        unless _tmp
          self.pos = _save22
          break
        end
        @result = begin;  "\035" ; end
        _tmp = true
        unless _tmp
          self.pos = _save22
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save23 = self.pos
      while true # sequence
        _tmp = match_string("RS")
        unless _tmp
          self.pos = _save23
          break
        end
        @result = begin;  "\036" ; end
        _tmp = true
        unless _tmp
          self.pos = _save23
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save24 = self.pos
      while true # sequence
        _tmp = match_string("US")
        unless _tmp
          self.pos = _save24
          break
        end
        @result = begin;  "\037" ; end
        _tmp = true
        unless _tmp
          self.pos = _save24
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save25 = self.pos
      while true # sequence
        _tmp = match_string("SP")
        unless _tmp
          self.pos = _save25
          break
        end
        @result = begin;  " " ; end
        _tmp = true
        unless _tmp
          self.pos = _save25
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save26 = self.pos
      while true # sequence
        _tmp = match_string("NUL")
        unless _tmp
          self.pos = _save26
          break
        end
        @result = begin;  "\000" ; end
        _tmp = true
        unless _tmp
          self.pos = _save26
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save27 = self.pos
      while true # sequence
        _tmp = match_string("SOH")
        unless _tmp
          self.pos = _save27
          break
        end
        @result = begin;  "\001" ; end
        _tmp = true
        unless _tmp
          self.pos = _save27
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save28 = self.pos
      while true # sequence
        _tmp = match_string("STX")
        unless _tmp
          self.pos = _save28
          break
        end
        @result = begin;  "\002" ; end
        _tmp = true
        unless _tmp
          self.pos = _save28
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save29 = self.pos
      while true # sequence
        _tmp = match_string("ETX")
        unless _tmp
          self.pos = _save29
          break
        end
        @result = begin;  "\003" ; end
        _tmp = true
        unless _tmp
          self.pos = _save29
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save30 = self.pos
      while true # sequence
        _tmp = match_string("EOT")
        unless _tmp
          self.pos = _save30
          break
        end
        @result = begin;  "\004" ; end
        _tmp = true
        unless _tmp
          self.pos = _save30
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save31 = self.pos
      while true # sequence
        _tmp = match_string("ENQ")
        unless _tmp
          self.pos = _save31
          break
        end
        @result = begin;  "\005" ; end
        _tmp = true
        unless _tmp
          self.pos = _save31
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save32 = self.pos
      while true # sequence
        _tmp = match_string("ACK")
        unless _tmp
          self.pos = _save32
          break
        end
        @result = begin;  "\006" ; end
        _tmp = true
        unless _tmp
          self.pos = _save32
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save33 = self.pos
      while true # sequence
        _tmp = match_string("BEL")
        unless _tmp
          self.pos = _save33
          break
        end
        @result = begin;  "\a" ; end
        _tmp = true
        unless _tmp
          self.pos = _save33
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save34 = self.pos
      while true # sequence
        _tmp = match_string("DLE")
        unless _tmp
          self.pos = _save34
          break
        end
        @result = begin;  "\020" ; end
        _tmp = true
        unless _tmp
          self.pos = _save34
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save35 = self.pos
      while true # sequence
        _tmp = match_string("DC1")
        unless _tmp
          self.pos = _save35
          break
        end
        @result = begin;  "\021" ; end
        _tmp = true
        unless _tmp
          self.pos = _save35
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save36 = self.pos
      while true # sequence
        _tmp = match_string("DC2")
        unless _tmp
          self.pos = _save36
          break
        end
        @result = begin;  "\022" ; end
        _tmp = true
        unless _tmp
          self.pos = _save36
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save37 = self.pos
      while true # sequence
        _tmp = match_string("DC3")
        unless _tmp
          self.pos = _save37
          break
        end
        @result = begin;  "\023" ; end
        _tmp = true
        unless _tmp
          self.pos = _save37
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save38 = self.pos
      while true # sequence
        _tmp = match_string("DC4")
        unless _tmp
          self.pos = _save38
          break
        end
        @result = begin;  "\024" ; end
        _tmp = true
        unless _tmp
          self.pos = _save38
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save39 = self.pos
      while true # sequence
        _tmp = match_string("NAK")
        unless _tmp
          self.pos = _save39
          break
        end
        @result = begin;  "\025" ; end
        _tmp = true
        unless _tmp
          self.pos = _save39
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save40 = self.pos
      while true # sequence
        _tmp = match_string("SYN")
        unless _tmp
          self.pos = _save40
          break
        end
        @result = begin;  "\026" ; end
        _tmp = true
        unless _tmp
          self.pos = _save40
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save41 = self.pos
      while true # sequence
        _tmp = match_string("ETB")
        unless _tmp
          self.pos = _save41
          break
        end
        @result = begin;  "\027" ; end
        _tmp = true
        unless _tmp
          self.pos = _save41
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save42 = self.pos
      while true # sequence
        _tmp = match_string("CAN")
        unless _tmp
          self.pos = _save42
          break
        end
        @result = begin;  "\030" ; end
        _tmp = true
        unless _tmp
          self.pos = _save42
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save43 = self.pos
      while true # sequence
        _tmp = match_string("SUB")
        unless _tmp
          self.pos = _save43
          break
        end
        @result = begin;  "\032" ; end
        _tmp = true
        unless _tmp
          self.pos = _save43
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save44 = self.pos
      while true # sequence
        _tmp = match_string("ESC")
        unless _tmp
          self.pos = _save44
          break
        end
        @result = begin;  "\e" ; end
        _tmp = true
        unless _tmp
          self.pos = _save44
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save45 = self.pos
      while true # sequence
        _tmp = match_string("DEL")
        unless _tmp
          self.pos = _save45
          break
        end
        @result = begin;  "\177" ; end
        _tmp = true
        unless _tmp
          self.pos = _save45
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save46 = self.pos
      while true # sequence
        _text_start = self.pos
        _tmp = get_byte
        if _tmp
          text = get_text(_text_start)
        end
        unless _tmp
          self.pos = _save46
          break
        end
        @result = begin;  "\\" + text ; end
        _tmp = true
        unless _tmp
          self.pos = _save46
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save
      break
    end # end choice

    set_failed_rule :_escapes unless _tmp
    return _tmp
  end

  # number_escapes = (/[xX]/ < /[0-9a-fA-F]{1,5}/ > { [text.to_i(16)].pack("U") } | < /\d{1,6}/ > { [text.to_i].pack("U") } | /[oO]/ < /[0-7]{1,7}/ > { [text.to_i(16)].pack("U") } | /[uU]/ < /[0-9a-fA-F]{4}/ > { [text.to_i(16)].pack("U") })
  def _number_escapes

    _save = self.pos
    while true # choice

      _save1 = self.pos
      while true # sequence
        _tmp = scan(/\A(?-mix:[xX])/)
        unless _tmp
          self.pos = _save1
          break
        end
        _text_start = self.pos
        _tmp = scan(/\A(?-mix:[0-9a-fA-F]{1,5})/)
        if _tmp
          text = get_text(_text_start)
        end
        unless _tmp
          self.pos = _save1
          break
        end
        @result = begin;  [text.to_i(16)].pack("U") ; end
        _tmp = true
        unless _tmp
          self.pos = _save1
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save2 = self.pos
      while true # sequence
        _text_start = self.pos
        _tmp = scan(/\A(?-mix:\d{1,6})/)
        if _tmp
          text = get_text(_text_start)
        end
        unless _tmp
          self.pos = _save2
          break
        end
        @result = begin;  [text.to_i].pack("U") ; end
        _tmp = true
        unless _tmp
          self.pos = _save2
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save3 = self.pos
      while true # sequence
        _tmp = scan(/\A(?-mix:[oO])/)
        unless _tmp
          self.pos = _save3
          break
        end
        _text_start = self.pos
        _tmp = scan(/\A(?-mix:[0-7]{1,7})/)
        if _tmp
          text = get_text(_text_start)
        end
        unless _tmp
          self.pos = _save3
          break
        end
        @result = begin;  [text.to_i(16)].pack("U") ; end
        _tmp = true
        unless _tmp
          self.pos = _save3
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save4 = self.pos
      while true # sequence
        _tmp = scan(/\A(?-mix:[uU])/)
        unless _tmp
          self.pos = _save4
          break
        end
        _text_start = self.pos
        _tmp = scan(/\A(?-mix:[0-9a-fA-F]{4})/)
        if _tmp
          text = get_text(_text_start)
        end
        unless _tmp
          self.pos = _save4
          break
        end
        @result = begin;  [text.to_i(16)].pack("U") ; end
        _tmp = true
        unless _tmp
          self.pos = _save4
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save
      break
    end # end choice

    set_failed_rule :_number_escapes unless _tmp
    return _tmp
  end

  # expressions = expression:e (- expression)*:es { [e] + Array(es).to_list }
  def _expressions

    _save = self.pos
    while true # sequence
      _tmp = apply(:_expression)
      e = @result
      unless _tmp
        self.pos = _save
        break
      end
      _ary = []
      while true

        _save2 = self.pos
        while true # sequence
          _tmp = apply(:__hyphen_)
          unless _tmp
            self.pos = _save2
            break
          end
          _tmp = apply(:_expression)
          unless _tmp
            self.pos = _save2
          end
          break
        end # end sequence

        _ary << @result if _tmp
        break unless _tmp
      end
      _tmp = true
      @result = _ary
      es = @result
      unless _tmp
        self.pos = _save
        break
      end
      @result = begin;  [e] + Array(es).to_list ; end
      _tmp = true
      unless _tmp
        self.pos = _save
      end
      break
    end # end sequence

    set_failed_rule :_expressions unless _tmp
    return _tmp
  end

  # root = - expressions:es - !. { Array(es).to_list }
  def _root

    _save = self.pos
    while true # sequence
      _tmp = apply(:__hyphen_)
      unless _tmp
        self.pos = _save
        break
      end
      _tmp = apply(:_expressions)
      es = @result
      unless _tmp
        self.pos = _save
        break
      end
      _tmp = apply(:__hyphen_)
      unless _tmp
        self.pos = _save
        break
      end
      _save1 = self.pos
      _tmp = get_byte
      _tmp = _tmp ? nil : true
      self.pos = _save1
      unless _tmp
        self.pos = _save
        break
      end
      @result = begin;  Array(es).to_list ; end
      _tmp = true
      unless _tmp
        self.pos = _save
      end
      break
    end # end sequence

    set_failed_rule :_root unless _tmp
    return _tmp
  end

  Rules = {}
  Rules[:__hyphen_] = rule_info("-", "(comment | /\\s/)*")
  Rules[:_identifier] = rule_info("identifier", "< /[\\p{L}\\p{S}\\d!@\#%&*\\-\\\\:.\\/\\?_]+/u > { text }")
  Rules[:_comment] = rule_info("comment", "/;.*?$/")
  Rules[:_expression] = rule_info("expression", "(number | string | constant | symbol | list)")
  Rules[:_number] = rule_info("number", "(< /[\\+\\-]?0[oO][0-7]+/ > { Hummus::Number.new(text.to_i(8)) } | < /[\\+\\-]?0[xX][\\da-fA-F]+/ > { Hummus::Number.new(text.to_i(16)) } | < /[\\+\\-]?\\d+(\\.\\d+)?[eE][\\+\\-]?\\d+/ > { Hummus::Number.new(text.to_f) } | < /[\\+\\-]?\\d+\\.\\d+/ > { Hummus::Number.new(text.to_f) } | < /[\\+\\-]?\\d+/ > { Hummus::Number.new(text.to_i) })")
  Rules[:_escape] = rule_info("escape", "(number_escapes | escapes)")
  Rules[:_str_seq] = rule_info("str_seq", "< /[^\\\\\"]+/ > { text }")
  Rules[:_string] = rule_info("string", "\"\\\"\" < (\"\\\\\" escape | str_seq)*:c > \"\\\"\" { Hummus::String.new(text.gsub(\"\\\\\\\"\", \"\\\"\")) }")
  Rules[:_symbol] = rule_info("symbol", "identifier:n { Hummus::Symbol.new(n.to_sym) }")
  Rules[:_constant] = rule_info("constant", "(\"\#t\" { Hummus::True } | \"\#f\" { Hummus::False } | \"\#ignore\" { Hummus::Ignore } | \"\#inert\" { Hummus::Inert })")
  Rules[:_list] = rule_info("list", "\"(\" - pairs:ps - \")\" { ps }")
  Rules[:_pairs] = rule_info("pairs", "(expression:a - \".\" - expression:b { Hummus::Pair.new(a, b) } | pairs:a - \".\" - expression:b { Hummus::Pair.new(a, b) } | expression:a - pairs:b { Hummus::Pair.new(a, b) } | expression:a { Hummus::Pair.new(a, Hummus::Null.new) } | { Hummus::Null.new })")
  Rules[:_escapes] = rule_info("escapes", "(\"n\" { \"\\n\" } | \"s\" { \" \" } | \"r\" { \"\\r\" } | \"t\" { \"\\t\" } | \"v\" { \"\\v\" } | \"f\" { \"\\f\" } | \"b\" { \"\\b\" } | \"a\" { \"\\a\" } | \"e\" { \"\\e\" } | \"\\\\\" { \"\\\\\" } | \"\\\"\" { \"\\\"\" } | \"BS\" { \"\\b\" } | \"HT\" { \"\\t\" } | \"LF\" { \"\\n\" } | \"VT\" { \"\\v\" } | \"FF\" { \"\\f\" } | \"CR\" { \"\\r\" } | \"SO\" { \"\\016\" } | \"SI\" { \"\\017\" } | \"EM\" { \"\\031\" } | \"FS\" { \"\\034\" } | \"GS\" { \"\\035\" } | \"RS\" { \"\\036\" } | \"US\" { \"\\037\" } | \"SP\" { \" \" } | \"NUL\" { \"\\000\" } | \"SOH\" { \"\\001\" } | \"STX\" { \"\\002\" } | \"ETX\" { \"\\003\" } | \"EOT\" { \"\\004\" } | \"ENQ\" { \"\\005\" } | \"ACK\" { \"\\006\" } | \"BEL\" { \"\\a\" } | \"DLE\" { \"\\020\" } | \"DC1\" { \"\\021\" } | \"DC2\" { \"\\022\" } | \"DC3\" { \"\\023\" } | \"DC4\" { \"\\024\" } | \"NAK\" { \"\\025\" } | \"SYN\" { \"\\026\" } | \"ETB\" { \"\\027\" } | \"CAN\" { \"\\030\" } | \"SUB\" { \"\\032\" } | \"ESC\" { \"\\e\" } | \"DEL\" { \"\\177\" } | < . > { \"\\\\\" + text })")
  Rules[:_number_escapes] = rule_info("number_escapes", "(/[xX]/ < /[0-9a-fA-F]{1,5}/ > { [text.to_i(16)].pack(\"U\") } | < /\\d{1,6}/ > { [text.to_i].pack(\"U\") } | /[oO]/ < /[0-7]{1,7}/ > { [text.to_i(16)].pack(\"U\") } | /[uU]/ < /[0-9a-fA-F]{4}/ > { [text.to_i(16)].pack(\"U\") })")
  Rules[:_expressions] = rule_info("expressions", "expression:e (- expression)*:es { [e] + Array(es).to_list }")
  Rules[:_root] = rule_info("root", "- expressions:es - !. { Array(es).to_list }")
end
