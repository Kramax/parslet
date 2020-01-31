
module Parslet::Atoms
  # A series of helper functions that have the common topic of flattening 
  # result values into the intermediary tree that consists of Ruby Hashes and 
  # Arrays. 
  #
  # This module has one main function, #flatten, that takes an annotated 
  # structure as input and returns the reduced form that users expect from 
  # Atom#parse. 
  #
  # NOTE: Since all of these functions are just that, functions without 
  # side effects, they are in a module and not in a class. Its hard to draw 
  # the line sometimes, but this is beyond. 
  #
  module CanFlatten
    # Takes a mixed value coming out of a parslet and converts it to a return
    # value for the user by dropping things and merging hashes. 
    #
    # Named is set to true if this result will be embedded in a Hash result from 
    # naming something using <code>.as(...)</code>. It changes the folding 
    # semantics of repetition.
    #
    def flatten(value, named=false)
      # Passes through everything that isn't an array of things
      return value unless value.instance_of? Array

      # Extracts the s-expression tag
      tag, *tail = value

      puts "flatten: tag is #{tag.inspect}"
      puts "flatten: value is #{value.inspect}"
      # Merges arrays:
      result = tail.
        map { |e| flatten(e) }            # first flatten each element

      case tag
        when :sequence
          return flatten_sequence(result)
        when :maybe
          return named ? result.first : result.first || ''
        when :repetition
          return flatten_repetition(result, named)
      end

      fail "BUG: Unknown tag #{tag.inspect}."
    end

    # Lisp style fold left where the first element builds the basis for 
    # an inject. 
    #
    def foldl(list, &block)
      return '' if list.empty?
      list[1..-1].inject(list.first, &block)
    end

    # Flatten results from a sequence of parslets. 
    # A sequence is generally something like "a >> b >> c"
    # The simplest case would be something like "X" >> "Y" >> "Z" which we want simplified to "XYZ"
    # A more complex case would be "x.as(:X) >> y.as(:Y)" which we want simplified to
    # the hash { :X = x, :Y = y}
    # The original parslet cannot handle this though: "x.as(:X) >> y.as(:X)" because it would
    # overwrite x with y when merged so you would lose the first expression. 
    # We want to improve this so that it would convert it to a repetition so it would result in
    # { :X =>[ x, y] }
    #
    # @api private
    #
    def flatten_sequence(list)
      puts "flatten_sequence: #{list.inspect}"
      foldl(list.compact) { |r, e|        # and then merge flat elements
        puts "flatten_sequence: maybe merge <#{r.inspect}>, <#{e.inspect}>"
        merge_fold(r, e)
      }
    end

    class ImplictRepetition
      attr_reader :contents
      attr_reader :key

      def initialize(key, l, r)
        if l.is_a?(ImplictRepetition)
          if l.key != key
            raise ParseFailed.new("Trying to merge hashes with different keys")
          end
          @contents = l.contents
          @contents << r
        else
          @contents = [l,r]
        end
        @key = key
      end
    end

    # @api private 
    def merge_fold(l, r)
      # equal pairs: merge. ----------------------------------------------------
      if l.is_a?(ImplictRepetition)
        if r.is_a?(Hash)
          if r.size != 1
            raise ParseFailed.new("Trying to merge hashes with unmergeable keys")
          end
          return ImplictRepetition.new(r.keys.first, l, r)
        end
      end

      if l.class == r.class
        if l.is_a?(Hash)
          can_merge = true
          akey = nil
          result = l.merge(r) { |key,l_val,r_val| 
            if l_val == r_val
              l_val
            else
              akey = key
              can_merge = false
              nil
            end
          }

          if can_merge
            return result
          end

          if l.size == 1 && r.size == 1
            #result = ImplictRepetition.new(akey, l, r)
            result = { }
            result[akey] = [ l[akey], r[akey]]
            puts "merge_fold: merged to <#{result}>"
            return result
          end

          # the .as(sym) needs to be refined for the parse node
          raise ParseFailed.new("Duplicate unmergeable named hashes <#{l.inspect}> and <#{r.inspect}>")
          
          #warn_about_duplicate_keys(l, r)
          #return l.merge(r)
        else
          return l + r
        end
      end

      # unequal pairs: hoist to same level. ------------------------------------

      # Maybe classes are not equal, but both are stringlike?
      if l.respond_to?(:to_str) && r.respond_to?(:to_str)
        # if we're merging a String with a Slice, the slice wins. 
        return r if r.respond_to? :to_slice
        return l if l.respond_to? :to_slice

        fail "NOTREACHED: What other stringlike classes are there?"
      end

      # special case: If one of them is a string/slice, the other is more important 
      return l if r.respond_to? :to_str
      return r if l.respond_to? :to_str

      # otherwise just create an array for one of them to live in 
      return l + [r] if r.class == Hash
      return [l] + r if l.class == Hash

      fail "Unhandled case when foldr'ing sequence."
    end

    # Flatten results from a repetition of a single parslet. named indicates
    # whether the user has named the result or not. If the user has named
    # the results, we want to leave an empty list alone - otherwise it is 
    # turned into an empty string. 
    #
    # @api private
    #
    def flatten_repetition(list, named)
      puts "flatten_repetition: #{named} <#{list.inspect}>"
      if list.any? { |e| e.instance_of?(Hash) }
        # If keyed subtrees are in the array, we'll want to discard all 
        # strings inbetween. To keep them, name them. 
        return list.select { |e| e.instance_of?(Hash) }
      end

      if list.any? { |e| e.instance_of?(Array) }
        # If any arrays are nested in this array, flatten all arrays to this
        # level. 
        return list.
          select { |e| e.instance_of?(Array) }.
          flatten(1)
      end

      # Consistent handling of empty lists, when we act on a named result        
      return [] if named && list.empty?

      # If there are only strings, concatenate them and return that. 
      foldl(list.compact) { |s,e| s+e }
    end

    # That annoying warning 'Duplicate subtrees while merging result' comes 
    # from here. You should add more '.as(...)' names to your intermediary tree.
    #
    def warn_about_duplicate_keys(h1, h2)
      d = h1.keys & h2.keys
      unless d.empty?
        warn "Duplicate subtrees while merging result of \n  #{self.inspect}\nonly the values"+
             " of the latter will be kept. (keys: #{d.inspect})"
             warn "h1 is #{h1.inspect}"
             warn "h2 is #{h2.inspect}"
      end
    end

    # can two hashes be merged: only if they have orthogonal keys
    def can_merge?(h1, h2)
      d = h1.keys & h2.keys
      return d.empty?
    end
  end
end