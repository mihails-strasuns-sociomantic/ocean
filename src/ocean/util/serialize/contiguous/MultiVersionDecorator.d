/******************************************************************************

    Enhancement to VersionDecorator that allows converting through multiple
    struct versions at once. It is kept separate from core implementation
    because additional overhead may be not suitable for real-time apps

    Copyright:
        Copyright (c) 2009-2016 Sociomantic Labs GmbH.
        All rights reserved.

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.
        Alternatively, this file may be distributed under the terms of the Tango
        3-Clause BSD License (see LICENSE_BSD.txt for details).

*******************************************************************************/

module ocean.util.serialize.contiguous.MultiVersionDecorator;


import ocean.transition;

import ocean.stdc.string : memmove;
import ocean.math.Math;

import ocean.core.Enforce,
       ocean.util.container.ConcatBuffer,
       ocean.core.StructConverter : structConvert;

import ocean.util.serialize.Version,
       ocean.util.serialize.model.VersionDecoratorMixins;

import ocean.util.serialize.contiguous.Serializer,
       ocean.util.serialize.contiguous.Deserializer,
       ocean.util.serialize.contiguous.Contiguous,
       ocean.util.serialize.contiguous.model.LoadCopyMixin;

import ocean.core.Buffer;
import ocean.core.Verify;
import ocean.core.Exception;

version (UnitTest)
{
    import core.memory;

    import ocean.core.Array;
    import ocean.core.Test;
    import ocean.text.convert.Formatter;
}


/*******************************************************************************

    Alternative contiguous version decorator implementation for usage in less
    performance critical applications. Is capable of converting through
    multiple struct versions in one go for added convenience.

    Amount of allowed conversions for single call is set via constructor
    argument, 10 by default

*******************************************************************************/

class VersionDecorator
{
    /***************************************************************************

        Convenience shortcut

    ***************************************************************************/

    public alias VersionDecorator This;

    /***************************************************************************

        Reused exception instance

    ***************************************************************************/

    protected VersionHandlingException e;

    /***************************************************************************

        Allowed difference between struct versions to be converted in one go

    ***************************************************************************/

    private size_t conversion_limit;

    /***************************************************************************

        Persistent buffer reused for temporary allocations needed for struct
        conversions between different versions

    ***************************************************************************/

    private ConcatBuffer!(void) convert_buffer;

    /***************************************************************************

        Struct buffer for copy of deserialized data needed for in-place
        deserialization with conversion

    ***************************************************************************/

    private Buffer!(void) struct_buffer;

    /***************************************************************************

        Constructor

        Params:
            limit = maximum allowed difference between struct versions
            buffer_size = starting this of convert_buffer, does not really
                matter much in practice because it will quickly grow to the
                maximum required size and stay there

    ***************************************************************************/

    public this (size_t limit = 10, size_t buffer_size = 512)
    {
        this.e = new VersionHandlingException;
        this.conversion_limit =limit;
        this.convert_buffer = new ConcatBuffer!(void)(buffer_size);
    }

    /***************************************************************************

        Serializes `input` with This.Serializer and prepends version number
        before struct data in the buffer.

        Params:
            input  = struct instance to serialize
            buffer = destination buffer for serialized data

        Returns:
            full slice of `buffer`

    ***************************************************************************/

    public static void[] store(S)(S input, ref Buffer!(void) buffer)
    {
        alias Version.Info!(S) VInfo;

        static assert (
            VInfo.exists,
            "Trying to use " ~ This.stringof ~ " with unversioned struct "
                ~ S.stringof
        );

        buffer.length = .Serializer.countRequiredSize(input)
            + Version.Type.sizeof;
        auto unversioned = Version.inject(buffer, VInfo.number);
        .Serializer.serialize(input, unversioned);

        verify(unversioned.ptr is (buffer[].ptr + Version.Type.sizeof));

        return buffer[];
    }

    /// ditto
    public static void[] store(S, D)(S input, ref D[] buffer)
    {
        static assert (D.sizeof == 1,
            "buffer can't be interpreted as void[]");
        return store!(S)(input, *cast(Buffer!(void)*) &buffer);
    }

    /***************************************************************************

        Loads versioned struct from `buffer` in-place

        If deserialized struct is of different version than requested one,
        converts it iteratively, one version increment/decrement at time.

        Params:
            buffer = data previously generated by `store` method, contains both
                version data and serialized struct. Will be extended if needed
                and modified in-place, version bytes removed

        Returns:
            part of `buffer` after deserialization and version stripping, may be
            wrapped in deserializer-specific struct

    ***************************************************************************/

    public Contiguous!(S) load(S)(ref Buffer!(void) buffer)
    {
        static assert (
            Version.Info!(S).exists,
            "Trying to use " ~ This.stringof ~ " with unversioned struct "
                ~ S.stringof
        );

        this.e.enforceInputLength!(S)(buffer.length);

        Version.Type input_version;
        auto unversioned = Version.extract(buffer[], input_version);
        // can't just do `buffer = unversioned` because it will create new
        // gc root and slowly leak memory with each load
        memmove(buffer[].ptr, unversioned.ptr, unversioned.length);

        return this.handleVersion!(S)(buffer, input_version);
    }

    /// ditto
    public Contiguous!(S) load(S)(ref void[] buffer)
    {
        return this.load!(S)(* cast(Buffer!(void)*) &buffer);
    }

    /***************************************************************************

        Loads versioned struct from `buffer` and stores resulting data
        in `copy_buffer`, leaving `buffer` untouched.

        If deserialized struct is of different version than requested one,
        converts it iteratively, one version increment/decrement at time.

        Params:
            buffer = data previously generated by `store` method, contains both
                version data and serialized struct. Effectively const
            copy_buffer = buffer where deserialized struct data will be stored.
                Will be extended if needed and won't contain version bytes

        Returns:
            slice of `buffer` after deserialization and version stripping

    ***************************************************************************/

    public Contiguous!(S) loadCopy(S)(in void[] buffer, ref Contiguous!(S) copy_buffer)
    {
        static assert (
            Version.Info!(S).exists,
            "Trying to use " ~ This.stringof ~ " with unversioned struct "
                ~ S.stringof
        );

        this.e.enforceInputLength!(S)(buffer.length);

        Version.Type input_version;
        auto unversioned = Version.extract(buffer, input_version);
        copy_buffer.data.length = unversioned.length;
        enableStomping(copy_buffer.data);
        copy_buffer.data[0 .. unversioned.length] = unversioned[];

        return this.handleVersion!(S)(copy_buffer.data, input_version);
    }

    /***************************************************************************

        Utility method to convert struct contained in input buffer to needed
        struct version. Converted struct will be stored in the same buffer
        replacing old data.

        You can override this method to change version converting logic.

        Params:
            S = final struct version to get
            buffer = input buffer after version bytes have been stripped off,
                will contain resulting struct data after this method exits
            input_version = version that was extracted from buffer

        Returns:
            deserialize() result for the last struct conversion

        Throws:
            VersionHandlingException if can't convert between provided versions

    ***************************************************************************/

    protected Contiguous!(S) handleVersion(S)
        (ref Buffer!(void) buffer, Version.Type input_version)
    {
        alias Version.Info!(S) VInfo;

        if (abs(input_version - VInfo.number) >= this.conversion_limit)
        {
            this.e.throwCantConvert!(S)(input_version);
        }

        if (input_version == VInfo.number)
        {
            // no conversion is necessary
            return .Deserializer.deserialize!(S)(buffer);
        }

        if (input_version > VInfo.number)
        {
            // input is of higher version, need to convert down
            static if (VInfo.next.exists)
            {
                this.handleVersion!(VInfo.next.type)(buffer, input_version);
                return this.convert!(S, VInfo.next.type)(buffer);
            }
            else
            {
                this.e.throwCantConvert!(S)(input_version);
            }
        }

        if (input_version < VInfo.number)
        {
            // input is of lower version, need to convert up
            static if (VInfo.prev.exists)
            {
                this.handleVersion!(VInfo.prev.type)(buffer, input_version);
                return this.convert!(S, VInfo.prev.type)(buffer);
            }
            else
            {
                this.e.throwCantConvert!(S)(input_version);
            }
        }

        assert(0);
    }

    /// ditto
    public Contiguous!(S) handleVersion(S)
        (ref void[] buffer, Version.Type input_version)
    {
        return handleVersion!(S)(*cast(Buffer!(void)*) &buffer,
            input_version);
    }

    /***************************************************************************

        Helper method that takes care of actual conversion routine between
        two struct types (those are assumed to be of compatible versions)

        Uses this.convert_buffer for temporary allocations

        Template_Params:
            S = needed struct type
            Source = struct type seralized into buffer

        Params:
            buffer = contains serialized Source instance, will be modified to
                store deserialized S instance instead.

    ***************************************************************************/

    public Contiguous!(S) convert (S, Source) (ref Buffer!(void) buffer)
    {
        scope(exit)
        {
            this.convert_buffer.clear();
        }

        if (this.struct_buffer.length < buffer.length)
            this.struct_buffer.length = buffer.length;
        this.struct_buffer[0 .. buffer.length] = buffer[];

        auto tmp_struct = .Deserializer.deserialize!(Source)(this.struct_buffer);
        S result_struct;
        structConvert!(Source, S)(
            *tmp_struct.ptr,
            result_struct,
            &this.convert_buffer.add
        );
        .Serializer.serialize(result_struct, buffer);
        return .Deserializer.deserialize!(S)(buffer);
    }

    /// ditto
    public Contiguous!(S) convert (S, Source) (ref void[] buffer)
    {
        return convert!(S, Source)(*cast(Buffer!(void)*) &buffer);
    }
}

/***************************************************************************

    Exception thrown when the loaded encounters any issues with version
    support

***************************************************************************/

public class VersionHandlingException : Exception
{
    mixin ReusableExceptionImplementation;

    /***************************************************************************

        Used to enforce that input is large enough to store version
        bytes and some offset.

        Params:
            input_length = size of input buffer
            file = inferred
            line = inferred

        Template_Params:
            S = struct type that was attempted to be loaded

    ***************************************************************************/

    void enforceInputLength(S)(size_t input_length,
        istring file = __FILE__, int line = __LINE__)
    {
        if (input_length <= Version.Type.sizeof)
        {
            this.set("Loading ")
                .append(S.stringof)
                .append(" has failed, input buffer too short (length ")
                .append(input_length)
                .append(", need ")
                .append(Version.Type.sizeof)
                .append(")");
            this.line = line;
            this.file = file;

            throw this;
        }
    }

    /***************************************************************************

        Used in case of version mismatch between requested struct and incoming
        buffer

        Params:
            input_version = version found in input buffer
            file = inferred
            line = inferred

        Template_Params:
            S = struct type that was attempted to be loaded

    ***************************************************************************/

    void throwCantConvert(S)(Version.Type input_version, istring file = __FILE__,
        int line = __LINE__)
    {
        this.set("Got version ")
            .append(input_version)
            .append(" for struct ")
            .append(S.stringof)
            .append(", expected ")
            .append(Version.Info!(S).number)
            .append(". Can't convert between these");
        this.line = line;
        this.file = file;

        throw this;
    }
}

version(UnitTest)
{
    struct Multi_Test1
    {
        static struct Version0
        {
            const StructVersion = 0;
            alias Version1 StructNext;

            int a, b;

            mstring[] strarr;
        }

        static struct Version1
        {
            const StructVersion = 1;
            alias Version0 StructPrevious;
            alias Version2 StructNext;

            int b, a;

            mstring[] strarr;
        }

        static struct Version2
        {
            const StructVersion = 2;
            alias Version1 StructPrevious;

            int a, b, c;

            mstring[] strarr;

            static void convert_c(ref Version1 s, ref Version2 dst)
            {
                dst.c = s.a + s.b;
            }
        }
    }
}

unittest
{
    // loadCopy

    auto loader = new VersionDecorator();
    auto ver0 = Multi_Test1.Version0(42, 43, ["version0".dup]);
    void[] serialized;
    Contiguous!(Multi_Test1.Version2) buffer;

    loader.store(ver0, serialized);
    auto ver2 = loader.loadCopy(serialized, buffer);

    testNoAlloc({
        auto ver2 = loader.loadCopy(serialized, buffer);
    } ());

    test!("==")(ver2.ptr.a, ver0.a);
    test!("==")(ver2.ptr.b, ver0.b);
    test!("==")(ver2.ptr.c, ver0.a + ver0.b);
    test!("==")(ver2.ptr.strarr, ver0.strarr);
}

unittest
{
    // in-place load

    auto loader = new VersionDecorator();

    auto ver0 = Multi_Test1.Version0(42, 43, ["version0".dup]);
    void[] buffer;

    loader.store(ver0, buffer);
    auto ver2 = loader.load!(Multi_Test1.Version2)(buffer);

    test!("==")(ver2.ptr.a, ver0.a);
    test!("==")(ver2.ptr.b, ver0.b);
    test!("==")(ver2.ptr.c, ver0.a + ver0.b);
    test!("==")(ver2.ptr.strarr, ver0.strarr);

    void[] buffer2;
    loader.store(*ver2.ptr, buffer2);
    auto ver0_again = loader.load!(Multi_Test1.Version0)(buffer2);

}

// error handling

version (UnitTest)
{
    struct Multi_Test2
    {
        static struct Version3
        {
            int a, b;
            const StructVersion = 3;
        }

        static struct VersionHuge
        {
            const StructVersion = 100;
        }
    }
}

unittest
{
    auto loader = new VersionDecorator();

    auto ver0 = Multi_Test1.Version0(42, 43, ["version0".dup]);
    void[] buffer;

    // version number difference too big
    loader.store(ver0, buffer);
    testThrown!(VersionHandlingException)(
        loader.load!(Multi_Test2.VersionHuge)(buffer)
    );

    // "next" alias is not defined
    loader.store(ver0, buffer);
    testThrown!(VersionHandlingException)(
        loader.load!(Multi_Test2.Version3)(buffer)
    );

    // "prev" alias is not defined
    loader.store(Multi_Test2.Version3.init, buffer);
    testThrown!(VersionHandlingException)(
        loader.load!(Multi_Test1.Version2)(buffer)
    );
}


version (UnitTest):

/*******************************************************************************

    No conversion. More extensively covered by (de)serializer base tests in
    package_test.d

*******************************************************************************/

unittest
{
    struct S
    {
        const StructVersion = 1;

        int    a = 42;
        double b = 2.0;
    }

    auto loader = new VersionDecorator;

    void[] buffer;
    S t;
    loader.store(t, buffer);

    Contiguous!(S) dst;
    loader.loadCopy!(S)(buffer, dst);

    test!("==")(dst.ptr.a, t.a);
    test!("==")(dst.ptr.b, t.b);

    dst = loader.load!(S)(buffer);

    test!("==")(dst.ptr.a, t.a);
    test!("==")(dst.ptr.b, t.b);
}

/*******************************************************************************

    No conversion. Check non void[] API.

*******************************************************************************/

unittest
{
    struct S
    {
        const StructVersion = 1;
        int a = 42;
    }

    auto loader = new VersionDecorator;

    ubyte[] buffer;
    S t;
    loader.store(t, buffer);

    Contiguous!(S) dst;
    loader.loadCopy!(S)(buffer, dst);

    test!("==")(dst.ptr.a, t.a);
}

/*******************************************************************************

    Error handling

*******************************************************************************/

unittest
{
    auto loader = new VersionDecorator;
    void[] buffer = null;

    // must not accept non-versioned

    struct NoVersion { }
    static assert (!is(typeof(loader.load!(NoVersion)(buffer))));

    // must detect if input size is too small

    struct Dummy { const StructVersion = 1; }

    testThrown!(VersionHandlingException)(loader.load!(Dummy)(buffer));

    Contiguous!(Dummy) dst;
    testThrown!(VersionHandlingException)(
        loader.loadCopy!(Dummy)(buffer, dst));

    // must detect if conversion is not defined

    struct Dummy2 { const StructVersion = 2; }

    loader.store(Dummy2.init, buffer);
    testThrown!(VersionHandlingException)(loader.load!(Dummy)(buffer));

    loader.store(Dummy.init, buffer);
    testThrown!(VersionHandlingException)(loader.load!(Dummy2)(buffer));
}

/*******************************************************************************

    Conversion from higher version, trivial struct

*******************************************************************************/

struct Test1
{
    struct Version1
    {
        const StructVersion = 1;

        alias Version2 StructNext;

        static void convert_a(ref Version2 src, ref Version1 dst)
        {
            dst.a = src.a + 1;
        }

        int a;
    }

    struct Version2
    {
        const StructVersion = 2;

        int a = 42;
    }
}

unittest
{
    auto loader = new VersionDecorator;

    with (Test1)
    {
        void[] buffer;
        Version2 t;
        loader.store(t, buffer);

        Contiguous!(Version1) dst;
        loader.loadCopy(buffer, dst);
        test!("==")(dst.ptr.a, t.a + 1);

        auto result = loader.load!(Version1)(buffer);
        test!("==")(result.ptr.a, t.a + 1);
    }
}

/*******************************************************************************

    Conversion from lower version, trivial struct

*******************************************************************************/

struct Test2
{
    struct Version1
    {
        const StructVersion = 1;

        int a;
    }

    struct Version2
    {
        const StructVersion = 2;

        alias Version1 StructPrevious;

        static void convert_a(ref Version1 src, ref Version2 dst)
        {
            dst.a = src.a + 1;
        }

        int a = 42;
    }
}

unittest
{
    auto loader = new VersionDecorator;

    with (Test2)
    {
        Buffer!(void) buffer;
        Version1 t;
        loader.store(t, buffer);

        Contiguous!(Version2) dst;
        loader.loadCopy(buffer[], dst);
        test!("==")(dst.ptr.a, t.a + 1);

        auto result = loader.load!(Version2)(buffer);
        test!("==")(result.ptr.a, t.a + 1);
    }
}

/*******************************************************************************

    Chained bi-directional conversions

*******************************************************************************/

struct Test3
{
    struct Version0
    {
        const ubyte StructVersion = 0;
        alias Version1 StructNext;

        struct Nested0
        {
            int a;
        }

        int a;
        int b;

        Nested0[] nested_arr;
        char[][]  string_arr;

        static Version0 create ()
        {
            Version0 t;

            t.a = 100;
            t.b = -100;
            t.nested_arr = [ Nested0(42), Nested0(43), Nested0(44) ];
            t.string_arr = [ "This".dup, "Is".dup,
                "A".dup, "Freaking".dup, "String!".dup ];

            return t;
        }

        void compare ( NamedTest t, Version0 other )
        {
            foreach (index, ref element; this.tupleof)
            {
                t.test!("==")(element, other.tupleof[index]);
            }
        }

        void compare ( NamedTest t, Version1 other )
        {
            foreach (index, ref element; this.tupleof)
            {
                const name = this.tupleof[index].stringof[
                    rfind(this.tupleof[index].stringof, "."[]) + 1 .. $
                ];

                static if (name == "nested_arr")
                {
                    foreach (i, elem; this.nested_arr)
                    {
                        t.test!("==")(elem.a, other.nested_arr[i].a);
                    }
                }
                else
                    mixin(`test!("==")(element, other.` ~ name ~ `);`);
            }
        }
    }

    struct Version1
    {
        const ubyte StructVersion = 1;
        alias Version0 StructPrevious;
        alias Version2 StructNext;

        struct Nested1
        {
            int a;
            int b;

            static void convert_b ( ref Version0.Nested0 s, ref Nested1 dst )
            {
                dst.b = s.a + 1;
            }
            static void convert_b ( ref Version2.Nested2 s, ref Nested1 dst )
            {
                dst.b = s.a / 2;
            }
        }

        int a;
        int b;
        int c;

        Nested1[] nested_arr;
        char[][]  string_arr;

        static void convert_c ( ref Version0 s, ref Version1 dst )
        {
            dst.c = s.b - s.a;
        }

        static void convert_c ( ref Version2 s, ref Version1 dst )
        {
            dst.c = s.d;
        }

        void compare ( NamedTest t, Version0 other )
        {
            foreach (index, ref member; this.tupleof)
            {
                const name = this.tupleof[index].stringof[
                    rfind(this.tupleof[index].stringof, "."[]) + 1 .. $
                ];

                static if (name == "nested_arr")
                {
                    foreach (i, ref nested; this.nested_arr)
                    {
                        test!("==")(nested.a, other.nested_arr[i].a);
                        test!("==")(nested.b, other.nested_arr[i].a + 1);
                    }
                }
                else static if (name == "c")
                {
                    test!("==")(this.c, other.b - other.a);
                }
                else
                {
                    mixin(`test!("==")(member, other.` ~ name ~ ");");
                }
            }
        }

        void compare ( NamedTest t, Version1 other )
        {
            foreach (index, ref element; this.tupleof)
            {
                t.test!("==")(element, other.tupleof[index]);
            }
        }

        void compare ( NamedTest t, Version2 other )
        {
            foreach (index, ref member; this.tupleof)
            {
                const name = this.tupleof[index].stringof[
                    rfind(this.tupleof[index].stringof, "."[]) + 1 .. $
                ];

                static if (name == "nested_arr")
                {
                    foreach (i, ref nested; this.nested_arr)
                    {
                        test!("==")(nested.a, other.nested_arr[i].a);
                        test!("==")(nested.b, other.nested_arr[i].a / 2);
                    }
                }
                else static if (name == "c")
                {
                    test!("==")(this.c, other.d);
                }
                else
                {
                    mixin(`test!("==")(member, other.` ~ name ~ ");");
                }
            }
        }
    }

    struct Version2
    {
        const ubyte StructVersion = 2;

        alias Version1 StructPrevious;

        struct Nested2
        {
            int a;

            static void convert_a ( ref Version1.Nested1 s, ref Nested2 dst )
            {
                dst.a = s.b * 2;
            }
        }

        Nested2[] nested_arr;

        int b;
        int a;
        int d;

        char[][] string_arr;

        static void convert_d ( ref Version1 s, ref Version2 dst )
        {
            dst.d = s.c;
        }

        void compare ( NamedTest t, ref Version0 other )
        {
            assert (false);
        }

        void compare ( NamedTest t, ref Version1 other )
        {
            foreach (index, ref member; this.tupleof)
            {
                const name = this.tupleof[index].stringof[
                    rfind(this.tupleof[index].stringof, "."[]) + 1 .. $
                ];

                static if (name == "nested_arr")
                {
                    foreach (i, ref nested; this.nested_arr)
                    {
                        test!("==")(nested.a, other.nested_arr[i].b * 2);
                    }
                }
                else static if (name == "d")
                {
                    test!("==")(this.d, other.c);
                }
                else
                {
                    mixin(`test!("==")(member, other.` ~ name ~ ");");
                }
            }
        }

        void compare ( NamedTest t, ref Version2 other )
        {
            foreach (index, member; this.tupleof)
            {
                t.test!("==")(member, other.tupleof[index]);
            }
        }
    }
}

Dst testConv(Src, Dst)(Src src, size_t limit = 10)
{
    auto test = new NamedTest(Src.stringof ~ " -> " ~ Dst.stringof);

    try
    {
        auto loader = new VersionDecorator(limit);
        void[] buffer;

        loader.store(src, buffer);
        auto dst = loader.load!(Dst)(buffer);
        dst.ptr.compare(test, src);

        return *dst.ptr;
    }
    catch (Exception e)
    {
        if (e.classinfo == TestException.classinfo)
            throw e;

        test.msg = format(
            "Unhandled exception of type {} from {}:{} - '{}'",
            e.classinfo.name,
            e.file,
            e.line,
            getMsg(e)
        );
        test.file = __FILE__;
        test.line = __LINE__;
        throw test;
    }
}

unittest
{
    with (Test3)
    {
        // internal sanity : exceptions must propagate as NamedTest exceptions
        testThrown!(NamedTest)(
            testConv!(Version0, Version2)(Version0.create(), 1)
        );

        auto ver0 = testConv!(Version0, Version0)(Version0.create());
        auto ver1 = testConv!(Version0, Version1)(ver0);
        auto ver2 = testConv!(Version1, Version2)(ver1);
        auto ver1_r = testConv!(Version2, Version1)(ver2);
        auto ver0_r = testConv!(Version1, Version0)(ver1_r);

        testConv!(Version1, Version1)(ver1);
        testConv!(Version2, Version2)(ver2);
    }
}

Dst testConvMemory(Src, Dst)(Src src, size_t limit = 10)
{
    auto test = new NamedTest(Src.stringof ~ " -> " ~ Dst.stringof);

    Contiguous!(Dst) result;
    auto loader = new VersionDecorator(limit);
    void[] buffer;

    const iterations = 10_000;

    static void storeThenLoad (ref NamedTest test, ref VersionDecorator loader,
                               ref Src src, ref void[] buffer,
                               ref Contiguous!(Dst) result)
    {
        try
        {
            loader.store(src, buffer);
            result = loader.load!(Dst)(buffer);
            //    result.ptr.compare(test, src);
        }
        catch (Exception e)
        {
            if (e.classinfo == TestException.classinfo)
                throw e;

            test.msg = format(
                "Unhandled exception of type {} from {}:{} - '{}'",
                e.classinfo.name,
                e.file,
                e.line,
                getMsg(e)
                );
            test.file = __FILE__;
            test.line = __LINE__;
            throw test;
        }
    }

    // After 1% of the iterations, memory usage shouldn't grow anymore
    for ( size_t i = 0; i < (iterations / 100); ++i )
    {
        storeThenLoad(test, loader, src, buffer, result);
    }

    // Do the other 99%
    testNoAlloc(
        {
            for ( size_t i = 0; i < iterations - (iterations / 100); ++i )
            {
                storeThenLoad(test, loader, src, buffer, result);
            }
        }());

    return *result.ptr;
}

unittest
{
    with (Test3)
    {
        // internal sanity : exceptions must propagate as NamedTest exceptions
        testThrown!(NamedTest)(
            testConvMemory!(Version0, Version2)(Version0.create(), 1)
        );

        auto ver0 = testConvMemory!(Version0, Version0)(Version0.create());
        auto ver1 = testConvMemory!(Version0, Version1)(ver0);
        auto ver2 = testConvMemory!(Version1, Version2)(ver1);
        auto ver1_r = testConvMemory!(Version2, Version1)(ver2);
        auto ver0_r = testConvMemory!(Version1, Version0)(ver1_r);

        testConvMemory!(Version1, Version1)(ver1);
        testConvMemory!(Version2, Version2)(ver2);
    }
}

/******************************************************************************

    Conversion which replaces struct fields completely

******************************************************************************/

struct Test4
{
    struct Ver0
    {
        const ubyte StructVersion = 0;
        int a;
    }

    struct Ver1
    {
        const ubyte StructVersion = 1;
        alias Test4.Ver0 StructPrevious;

        long b;
        static void convert_b(ref Ver0 rhs, ref Ver1 dst) { dst.b = 42; }
    }
}

unittest
{
    auto loader = new VersionDecorator;
    void[] buffer;

    auto src = Test4.Ver0(20);
    loader.store(src, buffer);
    auto dst = loader.load!(Test4.Ver1)(buffer);
    test!("==")(dst.ptr.b, 42);
}
