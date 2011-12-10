module Motion; module Project;
  class Vendor
    include Rake::DSL if Rake.const_defined?(:DSL)

    def initialize(path, type, config, opts)
      @path = path
      @type = type
      @config = config
      @opts = opts
      @libs = []
      @bs_files = []
    end

    attr_reader :libs, :bs_files

    def build(platform, archs)
      send gen_method('build'), platform, archs, @opts
    end

    def clean
      send gen_method('clean')
    end

    def build_xcode(platform, archs, opts)
      Dir.chdir(@path) do
        build_dir = "build-#{platform}"
        if !File.exist?(build_dir)
          FileUtils.mkdir build_dir

          # Prepare Xcode project settings.
          xcodeproj = opts.delete(:xcodeproj) || begin
            projs = Dir.glob('*.xcodeproj')
            if projs.size != 1
              $stderr.puts "Can't locate Xcode project file for vendor project #{@path}"
              exit 1
            end
            projs[0]
          end
          target = opts.delete(:target)
          scheme = opts.delete(:scheme)
          if target and scheme
            $stderr.puts "Both :target and :scheme are provided"
            exit 1
          end
          configuration = opts.delete(:configuration) || 'Release'
 
          # Build project into `build' directory. We delete the build directory each time because
          # Xcode is too stupid to be trusted to use the same build directory for different
          # platform builds.
          rm_rf 'build'
          xcopts = ''
          xcopts << "-target \"#{target}\" " if target
          xcopts << "-scheme \"#{scheme}\" " if scheme
          sh "/usr/bin/xcodebuild -project \"#{xcodeproj}\" #{xcopts} -configuration \"#{configuration}\" -sdk #{platform.downcase}#{@config.sdk_version} #{archs.map { |x| '-arch ' + x }.join(' ')} CONFIGURATION_BUILD_DIR=build build"
  
          # Copy .a files into the platform build directory.
          prods = opts.delete(:products)
          Dir.glob('build/*.a').each do |lib|
            next if prods and !prods.include?(File.basename(lib))
            lib = File.readlink(lib) if File.symlink?(lib)
            sh "/bin/cp \"#{lib}\" \"#{build_dir}\""      
          end
        end

        # Generate the bridgesupport file if we need to.
        bs_file = File.expand_path(File.basename(@path) + '.bridgesupport')
        headers_dir = opts.delete(:headers_dir)
        if !File.exist?(bs_file) and headers_dir
          Dir.chdir(headers_dir) do
            sh "/usr/bin/gen_bridge_metadata --format complete --no-64-bit --cflags \"-I.\" *.h -o \"#{bs_file}\""
          end 
        end

        @bs_files.clear
        @bs_files.concat(Dir.glob('*.bridgesupport').map { |x| File.expand_path(x) })

        @libs.clear
        @libs.concat(Dir.glob("#{build_dir}/*.a").map { |x| File.expand_path(x) })
      end
    end

    def clean_xcode
      Dir.chdir(@path) do
        rm_rf 'build', 'build-iPhoneOS', 'build-iPhoneSimulator'
      end
    end

    private

    def gen_method(prefix)
      method = "#{prefix}_#{@type.to_s}".intern
      raise "Invalid vendor project type: #{@type}" unless respond_to?(method)
      method
    end
  end
end; end
