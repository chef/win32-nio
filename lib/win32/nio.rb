require 'ffi'

require File.join(File.dirname(__FILE__), 'windows/functions')
require File.join(File.dirname(__FILE__), 'windows/constants')
require File.join(File.dirname(__FILE__), 'windows/structs')
require File.join(File.dirname(__FILE__), 'windows/macros')

# The Win32 module serves as a namespace only.
module Win32

  # The NIO class encapsulates the native IO methods for MS Windows.
  class NIO
    include Windows::Constants
    include Windows::Structs
    extend  Windows::Functions
    extend  Windows::Macros

    # The version of the win32-nio library
    VERSION = '0.1.0'

    # This method is similar to Ruby's IO.read method except that it uses
    # native function calls.
    #
    # Examples:
    #
    # # Read everything
    # Win32::NIO.read(file)
    #
    # # Read the first 100 bytes
    # Win32::NIO.read(file, 100)
    #
    # # Read 50 bytes starting at offset 10
    # Win32::NIO.read(file, 50, 10)
    #
    # Note that the +options+ that may be passed to this method are limited
    # to encoding: and mode: because we're no longer using the open function
    # internally. In the case of mode: the only thing that is checked for is
    # the presence of the 'b' (binary) mode.
    #--
    # In practice the fact that I ignore open_args: is irrelevant since you
    # would never want to open in anything other than GENERIC_READ. I suppose
    # I could change this to as a way to pass flags to CreateFile.
    #
    def self.read(name, length=nil, offset=0, options={})
      begin
        fname = name + "\0"
        fname.encode!('UTF-16LE')

        handle = CreateFileW(
          fname,
          GENERIC_READ,
          FILE_SHARE_READ,
          nil,
          OPEN_EXISTING,
          FILE_FLAG_SEQUENTIAL_SCAN,
          0
        )

        if handle == INVALID_HANDLE_VALUE
          raise SystemCallError, FFI.errno, "CreateFile"
        end

        length ||= File.size(name)

        olap  = Overlapped.new
        buf   = 0.chr * length
        bytes = FFI::MemoryPointer.new(:ulong)

        olap[:Offset] = offset

        bool = ReadFile(handle, buf, buf.size, bytes, olap)

        unless bool
          raise SystemCallError, FFI.errno, "ReadFile"
        end

        result = buf.delete(0.chr)

        result.encode!(options[:encoding]) if options[:encoding]

        if options[:mode] && options[:mode].include?('t') && ($/ != "\r\n")
          result.gsub!(/\r\n/, $/)
        end

        result
      ensure
        CloseHandle(handle) if handle && handle != INVALID_HANDLE_VALUE
      end
    end # NIO.read

    def self.readlines(file, sep = "\r\n")
      fname = file + "\0"
      fname.encode!('UTF-16LE')

      begin
        handle = CreateFileW(
          fname,
          GENERIC_READ,
          FILE_SHARE_READ,
          nil,
          OPEN_EXISTING,
          FILE_FLAG_OVERLAPPED | FILE_FLAG_NO_BUFFERING,
          0
        )

        if handle == INVALID_HANDLE_VALUE
          raise SystemCallError, FFI.errno, "CreateFileW"
        end

        sysinfo = SystemInfo.new
        GetSystemInfo(sysinfo)

        file_size = File.size(file)
        page_size = sysinfo[:dwPageSize]
        page_num  = (file_size.to_f / page_size).ceil

        begin
          size = page_size * page_num
          base_address = VirtualAlloc(nil, size, MEM_COMMIT, PAGE_READWRITE)

          if base_address == 0
            raise SystemCallError, FFI.errno, "VirtualAlloc"
          end

          # Add 1 for null as per the docs
          array = FFI::MemoryPointer.new(FileSegmentElement, page_num + 1)

          for i in 0...page_num
            fse = FileSegmentElement.new(array[i])
            fse[:Alignment] = base_address + page_size * i
          end

          overlapped = Overlapped.new

          bool = ReadFileScatter(handle, array, size, nil, overlapped)

          unless bool
            error = FFI.errno
            if error == ERROR_IO_PENDING
              SleepEx(1, true) while !HasOverlappedIoCompleted(overlapped)
            else
              raise SystemCallError, error, "ReadFileScatter"
            end
          end

          string = array[0].read_pointer.read_string

          if sep == ""
            array = string.split(/(\r\n){2,}/)
            array.delete("\r\n")
          else
            array = string.split(sep)
          end

          array
        ensure
          VirtualFree(base_address, 0, MEM_RELEASE)
        end
      ensure
        CloseHandle(handle) if handle && handle != INVALID_HANDLE_VALUE
      end
    end # NIO.readlines

  end # NIO
end # Win32
