require 'dl'
require 'dl/pack.rb'

module DL
  # C struct shell
  class CStruct
    # accessor to DL::CStructEntity
    def CStruct.entity_class()
      CStructEntity
    end
  end

  # C union shell
  class CUnion
    # accessor to DL::CUnionEntity
    def CUnion.entity_class()
      CUnionEntity
    end
  end

  # Used to construct C classes (CUnion, CStruct, etc)
  #
  # DL::Importer#struct and DL::Importer#union wrap this functionality in an
  # easy-to-use manner.
  module CStructBuilder
    # Construct a new class given a C:
    # * class +klass+ (CUnion, CStruct, or other that provide an
    #   #entity_class)
    # * +types+ (DL:TYPE_INT, DL::TYPE_SIZE_T, etc., see the C types
    #   constants)
    # * corresponding +members+
    #
    # DL::Importer#struct and DL::Importer#union wrap this functionality in an
    # easy-to-use manner.
    #
    # Example:
    #
    #   require 'dl/struct'
    #   require 'dl/cparser'
    #
    #   include DL::CParser
    #
    #   types, members = parse_struct_signature(['int i','char c'])
    #
    #   MyStruct = DL::CStructBuilder.create(CUnion, types, members)
    #
    #   obj = MyStruct.allocate
    #
    def create(klass, types, members)
      new_class = Class.new(klass){
        define_method(:initialize){|addr|
          @entity = klass.entity_class.new(addr, types)
          @entity.assign_names(members)
        }
        define_method(:to_ptr){ @entity }
        define_method(:to_i){ @entity.to_i }
        members.each{|name|
          define_method(name){ @entity[name] }
          define_method(name + "="){|val| @entity[name] = val }
        }
      }
      size = klass.entity_class.size(types)
      new_class.module_eval(<<-EOS, __FILE__, __LINE__+1)
        def new_class.size()
          #{size}
        end
        def new_class.malloc()
          addr = DL.malloc(#{size})
          new(addr)
        end
      EOS
      return new_class
    end
    module_function :create
  end

  # A C struct wrapper
  class CStructEntity < CPtr
    include PackInfo
    include ValueUtil

    # Allocates a C struct the +types+ provided.  The C function +func+ is
    # called when the instance is garbage collected.
    def CStructEntity.malloc(types, func = nil)
      addr = DL.malloc(CStructEntity.size(types))
      CStructEntity.new(addr, types, func)
    end

    # Given +types+, returns the offset for the packed sizes of those types
    #
    #   DL::CStructEntity.size([DL::TYPE_DOUBLE, DL::TYPE_INT, DL::TYPE_CHAR,
    #                           DL::TYPE_VOIDP])
    #   => 24
    def CStructEntity.size(types)
      offset = 0
      max_align = 0
      types.each_with_index{|t,i|
        orig_offset = offset
        if( t.is_a?(Array) )
          align = PackInfo::ALIGN_MAP[t[0]]
          offset = PackInfo.align(orig_offset, align)
          size = offset - orig_offset
          offset += (PackInfo::SIZE_MAP[t[0]] * t[1])
        else
          align = PackInfo::ALIGN_MAP[t]
          offset = PackInfo.align(orig_offset, align)
          size = offset - orig_offset
          offset += PackInfo::SIZE_MAP[t]
        end
        if (max_align < align)
          max_align = align
        end
      }
      offset = PackInfo.align(offset, max_align)
      offset
    end

    # Wraps the C pointer +addr+ as a C struct with the given +types+.  The C
    # function +func+ is called when the instance is garbage collected.
    #
    # See also DL::CPtr.new
    def initialize(addr, types, func = nil)
      set_ctypes(types)
      super(addr, @size, func)
    end

    # Set the names of the +members+ in this C struct
    def assign_names(members)
      @members = members
    end

    # Given +types+, calculate the offsets and sizes for the types in the
    # struct.
    def set_ctypes(types)
      @ctypes = types
      @offset = []
      offset = 0
      max_align = 0
      types.each_with_index{|t,i|
        orig_offset = offset
        if( t.is_a?(Array) )
          align = ALIGN_MAP[t[0]]
        else
          align = ALIGN_MAP[t]
        end
        offset = PackInfo.align(orig_offset, align)
        @offset[i] = offset
        if( t.is_a?(Array) )
          offset += (SIZE_MAP[t[0]] * t[1])
        else
          offset += SIZE_MAP[t]
        end
        if (max_align < align)
          max_align = align
        end
      }
      offset = PackInfo.align(offset, max_align)
      @size = offset
    end

    # Fetch struct member +name+
    def [](name)
      idx = @members.index(name)
      if( idx.nil? )
        raise(ArgumentError, "no such member: #{name}")
      end
      ty = @ctypes[idx]
      if( ty.is_a?(Array) )
        r = super(@offset[idx], SIZE_MAP[ty[0]] * ty[1])
      else
        r = super(@offset[idx], SIZE_MAP[ty.abs])
      end
      packer = Packer.new([ty])
      val = packer.unpack([r])
      case ty
      when Array
        case ty[0]
        when TYPE_VOIDP
          val = val.collect{|v| CPtr.new(v)}
        end
      when TYPE_VOIDP
        val = CPtr.new(val[0])
      else
        val = val[0]
      end
      if( ty.is_a?(Integer) && (ty < 0) )
        return unsigned_value(val, ty)
      elsif( ty.is_a?(Array) && (ty[0] < 0) )
        return val.collect{|v| unsigned_value(v,ty[0])}
      else
        return val
      end
    end

    # Set struct member +name+, to value +val+
    def []=(name, val)
      idx = @members.index(name)
      if( idx.nil? )
        raise(ArgumentError, "no such member: #{name}")
      end
      ty  = @ctypes[idx]
      packer = Packer.new([ty])
      val = wrap_arg(val, ty, [])
      buff = packer.pack([val].flatten())
      super(@offset[idx], buff.size, buff)
      if( ty.is_a?(Integer) && (ty < 0) )
        return unsigned_value(val, ty)
      elsif( ty.is_a?(Array) && (ty[0] < 0) )
        return val.collect{|v| unsigned_value(v,ty[0])}
      else
        return val
      end
    end

    def to_s() # :nodoc:
      super(@size)
    end
  end

  # A C union wrapper
  class CUnionEntity < CStructEntity
    include PackInfo

    # Allocates a C union the +types+ provided.  The C function +func+ is
    # called when the instance is garbage collected.
    def CUnionEntity.malloc(types, func=nil)
      addr = DL.malloc(CUnionEntity.size(types))
      CUnionEntity.new(addr, types, func)
    end

    # Given +types+, returns the size needed for the union.
    #
    #   DL::CUnionEntity.size([DL::TYPE_DOUBLE, DL::TYPE_INT, DL::TYPE_CHAR,
    #                          DL::TYPE_VOIDP])
    #   => 8
    def CUnionEntity.size(types)
      size   = 0
      types.each_with_index{|t,i|
        if( t.is_a?(Array) )
          tsize = PackInfo::SIZE_MAP[t[0]] * t[1]
        else
          tsize = PackInfo::SIZE_MAP[t]
        end
        if( tsize > size )
          size = tsize
        end
      }
    end

    # Given +types+, calculate the necessary offset and for each union member
    def set_ctypes(types)
      @ctypes = types
      @offset = []
      @size   = 0
      types.each_with_index{|t,i|
        @offset[i] = 0
        if( t.is_a?(Array) )
          size = SIZE_MAP[t[0]] * t[1]
        else
          size = SIZE_MAP[t]
        end
        if( size > @size )
          @size = size
        end
      }
    end
  end
end

