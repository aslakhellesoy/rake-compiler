#!/usr/bin/env ruby

# Define a series of tasks to aid in the compilation of C extensions for
# gem developer/creators.

require 'rake'
require 'rake/clean'
require 'rake/tasklib'
require 'rbconfig'
require 'yaml'
require 'pathname'

module Rake
  autoload :GemPackageTask, 'rake/gempackagetask'

  class ExtensionTask < TaskLib
    attr_accessor :name
    attr_accessor :gem_spec
    attr_accessor :config_script
    attr_accessor :tmp_dir
    attr_accessor :ext_dir
    attr_accessor :java_ext_dir
    attr_accessor :java_classpath
    attr_accessor :lib_dir
    attr_accessor :platform
    attr_accessor :config_options
    attr_accessor :source_pattern
    attr_accessor :cross_compile
    attr_accessor :cross_platform
    attr_accessor :cross_config_options
    attr_accessor :no_native

    def initialize(name = nil, gem_spec = nil)
      init(name, gem_spec)
      yield self if block_given?
      define
    end

    def init(name = nil, gem_spec = nil)
      @name = name
      @gem_spec = gem_spec
      @config_script = 'extconf.rb'
      @tmp_dir = 'tmp'
      @ext_dir = "ext/#{@name}"
      @java_ext_dir = 'ext-java/src/main/java'
      @lib_dir = 'lib'
      @java_classpath = nil
      @source_pattern = "*.c"
      @config_options = []
      @cross_compile = false
      @cross_config_options = []
      @cross_compiling = nil
      @no_native = false
    end

    def platform
      @platform ||= RUBY_PLATFORM
    end

    def cross_platform
      @cross_platform ||= 'i386-mingw32'
    end

    def cross_compiling(&block)
      @cross_compiling = block if block_given?
    end

    def define
      fail "Extension name must be provided." if @name.nil?

      define_compile_tasks

      # only gems with 'ruby' platforms are allowed to define native tasks
      define_native_tasks if !@no_native && (@gem_spec && @gem_spec.platform == 'ruby')

      # only define cross platform functionality when enabled
      return unless @cross_compile

      if cross_platform.is_a?(Array) then
        cross_platform.each { |platf| define_cross_platform_tasks(platf) }
      else
        define_cross_platform_tasks(cross_platform)
      end
    end

    private
    def define_compile_tasks(for_platform = nil, ruby_ver = RUBY_VERSION)
      # platform usage
      platf = for_platform || platform

      # lib_path
      lib_path = lib_dir

      # tmp_path
      tmp_path = "#{@tmp_dir}/#{platf}/#{@name}/#{ruby_ver}"

      # cleanup and clobbering
      CLEAN.include(tmp_path)
      CLOBBER.include("#{lib_path}/#{binary(platf)}")
      CLOBBER.include("#{@tmp_dir}")

      # directories we need
      directory tmp_path
      directory lib_dir

      # copy binary from temporary location to final lib
      # tmp/extension_name/extension_name.{so,bundle} => lib/
      task "copy:#{@name}:#{platf}:#{ruby_ver}" => [lib_path, "#{tmp_path}/#{binary(platf)}"] do
        cp "#{tmp_path}/#{binary(platf)}", "#{lib_path}/#{binary(platf)}"
      end

      if platf == 'java'

        not_jruby_compile_msg = <<-EOF
WARNING: You're cross-compiling a binary extension for JRuby, but are using
another interpreter. If your Java classpath or extension dir settings are not
correctly detected, then either check the appropriate environment variables or
execute the Rake compilation task using the JRuby interpreter.
(e.g. `jruby -S rake compile:java`)
        EOF
        warn(not_jruby_compile_msg) unless defined?(JRUBY_VERSION)

        file "#{tmp_path}/#{binary(platf)}" => [tmp_path] + java_source_files do
          #chdir tmp_path do
            classpath_arg = java_classpath_arg(@java_classpath)

            # Check if CC_JAVA_DEBUG env var was set to TRUE
            # TRUE means compile java classes with debug info
            debug_arg = if ENV['CC_JAVA_DEBUG'] && ENV['CC_JAVA_DEBUG'].upcase.eql?("TRUE")
              '-g'
            else
              ''
            end

            sh "javac #{java_extdirs_arg} -target 1.5 -source 1.5 -Xlint:unchecked #{debug_arg} #{classpath_arg} -d #{tmp_path} #{java_source_files.join(' ')}"
            sh "jar cf #{tmp_path}/#{binary(platf)} -C #{tmp_path} ."
          #end
        end

      else

        # binary in temporary folder depends on makefile and source files
        # tmp/extension_name/extension_name.{so,bundle}
        file "#{tmp_path}/#{binary(platf)}" => ["#{tmp_path}/Makefile"] + source_files do
          chdir tmp_path do
            sh make
          end
        end

        # makefile depends of tmp_dir and config_script
        # tmp/extension_name/Makefile
        file "#{tmp_path}/Makefile" => [tmp_path, extconf] do |t|
          options = @config_options.dup

          # include current directory
          cmd = ['-I.']

          # if fake.rb is present, add to the command line
          if t.prerequisites.include?("#{tmp_path}/fake.rb") then
            cmd << '-rfake'
          end

          # build a relative path to extconf script
          abs_tmp_path = Pathname.new(Dir.pwd) + tmp_path
          abs_extconf = Pathname.new(Dir.pwd) + extconf

          # now add the extconf script
          cmd << abs_extconf.relative_path_from(abs_tmp_path)

          # rbconfig.rb will be present if we are cross compiling
          if t.prerequisites.include?("#{tmp_path}/rbconfig.rb") then
            options.push(*@cross_config_options)
          end

          # add options to command
          cmd.push(*options)

          chdir tmp_path do
            # FIXME: Rake is broken for multiple arguments system() calls.
            # Add current directory to the search path of Ruby
            # Also, include additional parameters supplied.
            ruby cmd.join(' ')
          end
        end

      end

      # compile tasks
      unless Rake::Task.task_defined?('compile') then
        desc "Compile all the extensions"
        task "compile"
      end

      # compile:name
      unless Rake::Task.task_defined?("compile:#{@name}") then
        desc "Compile #{@name}"
        task "compile:#{@name}"
      end

      # Allow segmented compilation by platform (open door for 'cross compile')
      task "compile:#{@name}:#{platf}" => ["copy:#{@name}:#{platf}:#{ruby_ver}"]
      task "compile:#{platf}" => ["compile:#{@name}:#{platf}"]

      # Only add this extension to the compile chain if current
      # platform matches the indicated one.
      if platf == RUBY_PLATFORM then
        # ensure file is always copied
        file "#{lib_path}/#{binary(platf)}" => ["copy:#{name}:#{platf}:#{ruby_ver}"]

        task "compile:#{@name}" => ["compile:#{@name}:#{platf}"]
        task "compile" => ["compile:#{platf}"]
      end
    end

    def define_native_tasks(for_platform = nil, ruby_ver = RUBY_VERSION, callback = nil)
      platf = for_platform || platform

      # tmp_path
      tmp_path = "#{@tmp_dir}/#{platf}/#{@name}/#{ruby_ver}"

      # lib_path
      lib_path = lib_dir

      # create 'native:gem_name' and chain it to 'native' task
      unless Rake::Task.task_defined?("native:#{@gem_spec.name}:#{platf}")
        task "native:#{@gem_spec.name}:#{platf}" do |t|
          # FIXME: truly duplicate the Gem::Specification
          # workaround the lack of #dup for Gem::Specification
          spec = gem_spec.dup

          # adjust to specified platform
          spec.platform = Gem::Platform.new(platf)

          # clear the extensions defined in the specs
          spec.extensions.clear

          # add the binaries that this task depends on
          ext_files = []

          # go through native prerequisites and grab the real extension files from there
          t.prerequisites.each do |ext|
            ext_files << ext
          end

          # include the files in the gem specification
          spec.files += ext_files

          # expose gem specification for customization
          if callback
            callback.call(spec)
          end

          # Generate a package for this gem
          gem_package = Rake::GemPackageTask.new(spec) do |pkg|
            pkg.need_zip = false
            pkg.need_tar = false
          end
        end
      end

      # add binaries to the dependency chain
      task "native:#{@gem_spec.name}:#{platf}" => ["#{lib_path}/#{binary(platf)}"]

      # ensure the extension get copied
      unless Rake::Task.task_defined?("#{lib_path}/#{binary(platf)}") then
        file "#{lib_path}/#{binary(platf)}" => ["copy:#{@name}:#{platf}:#{ruby_ver}"]
      end

      # Allow segmented packaging by platform (open door for 'cross compile')
      task "native:#{platf}" => ["native:#{@gem_spec.name}:#{platf}"]

      # Only add this extension to the compile chain if current
      # platform matches the indicated one.
      if platf == RUBY_PLATFORM then
        task "native:#{@gem_spec.name}" => ["native:#{@gem_spec.name}:#{platf}"]
        task "native" => ["native:#{platf}"]
      end
    end

    def define_cross_platform_tasks(for_platform)
      if for_platform == 'java'
        define_java_platform_tasks(for_platform)
      else
        if ruby_vers = ENV['RUBY_CC_VERSION']
          ruby_vers = ENV['RUBY_CC_VERSION'].split(File::PATH_SEPARATOR)
        else
          ruby_vers = [RUBY_VERSION]
        end

        multi = (ruby_vers.size > 1) ? true : false

        ruby_vers.each do |version|
          # save original lib_dir
          orig_lib_dir = @lib_dir

          # tweak lib directory only when targeting multiple versions
          if multi then
            version =~ /(\d+.\d+)/
            @lib_dir = "#{@lib_dir}/#{$1}"
          end

          define_cross_platform_tasks_with_version(for_platform, version)

          # restore lib_dir
          @lib_dir = orig_lib_dir
        end
      end
    end

    def define_java_platform_tasks(for_platform)

      # HACK (we don't need/use this currently)
      ruby_ver = RUBY_VERSION

      # tmp_path
      tmp_path = "#{@tmp_dir}/#{for_platform}/#{@name}/#{ruby_ver}"

      # lib_path
      lib_path = lib_dir

      define_compile_tasks(for_platform)

      # create java task
      task 'java' do
        # clear compile dependencies
        Rake::Task['compile'].prerequisites.reject! { |t| !compiles_cross_platform.include?(t) }

        # chain the cross platform ones
        task 'compile' => ["compile:#{for_platform}"]

        # clear lib/binary dependencies and trigger cross platform ones
        # check if lib/binary is defined (damn bundle versus so versus dll)
        if Rake::Task.task_defined?("#{lib_path}/#{binary(for_platform)}") then
          Rake::Task["#{lib_path}/#{binary(for_platform)}"].prerequisites.clear
        end

        # FIXME: targeting multiple platforms copies the file twice
        file "#{lib_path}/#{binary(for_platform)}" => ["copy:#{@name}:#{for_platform}:#{ruby_ver}"]

        # if everything for native task is in place
        if @gem_spec && @gem_spec.platform == 'ruby' then
          # double check: only cross platform native tasks should be here
          # FIXME: Sooo brittle
          Rake::Task['native'].prerequisites.reject! { |t| !natives_cross_platform.include?(t) }
          task 'native' => ["native:#{for_platform}"]
        end
      end
    end

    def define_cross_platform_tasks_with_version(for_platform, ruby_ver)
      config_path = File.expand_path("~/.rake-compiler/config.yml")

      # warn the user about the need of configuration to use cross compilation.
      unless File.exist?(config_path)
        warn "rake-compiler must be configured first to enable cross-compilation"
        return
      end

      config_file = YAML.load_file(config_path)

      # tmp_path
      tmp_path = "#{@tmp_dir}/#{for_platform}/#{@name}/#{ruby_ver}"

      # lib_path
      lib_path = lib_dir

      unless rbconfig_file = config_file["rbconfig-#{ruby_ver}"] then
        warn "no configuration section for specified version of Ruby (rbconfig-#{ruby_ver})"
        return
      end

      # mkmf
      mkmf_file = File.expand_path(File.join(File.dirname(rbconfig_file), '..', 'mkmf.rb'))

      # define compilation tasks for cross platform!
      define_compile_tasks(for_platform, ruby_ver)

      # chain fake.rb, rbconfig.rb and mkmf.rb to Makefile generation
      file "#{tmp_path}/Makefile" => ["#{tmp_path}/fake.rb",
                                      "#{tmp_path}/rbconfig.rb",
                                      "#{tmp_path}/mkmf.rb"]

      # copy the file from the cross-ruby location
      file "#{tmp_path}/rbconfig.rb" => [rbconfig_file] do |t|
        cp t.prerequisites.first, t.name
      end

      # copy mkmf from cross-ruby location
      file "#{tmp_path}/mkmf.rb" => [mkmf_file] do |t|
        cp t.prerequisites.first, t.name
      end

      # genearte fake.rb for different ruby versions
      file "#{tmp_path}/fake.rb" do |t|
        File.open(t.name, 'w') do |f|
          f.write fake_rb(ruby_ver)
        end
      end

      # now define native tasks for cross compiled files
      if @gem_spec && @gem_spec.platform == 'ruby' then
        define_native_tasks(for_platform, ruby_ver, @cross_compiling)
      end

      # create cross task
      task 'cross' do
        # clear compile dependencies
        Rake::Task['compile'].prerequisites.reject! { |t| !compiles_cross_platform.include?(t) }

        # chain the cross platform ones
        task 'compile' => ["compile:#{for_platform}"]

        # clear lib/binary dependencies and trigger cross platform ones
        # check if lib/binary is defined (damn bundle versus so versus dll)
        if Rake::Task.task_defined?("#{lib_path}/#{binary(for_platform)}") then
          Rake::Task["#{lib_path}/#{binary(for_platform)}"].prerequisites.clear
        end

        # FIXME: targeting multiple platforms copies the file twice
        file "#{lib_path}/#{binary(for_platform)}" => ["copy:#{@name}:#{for_platform}:#{ruby_ver}"]

        # if everything for native task is in place
        if @gem_spec && @gem_spec.platform == 'ruby' then
          # double check: only cross platform native tasks should be here
          # FIXME: Sooo brittle
          Rake::Task['native'].prerequisites.reject! { |t| !natives_cross_platform.include?(t) }
          task 'native' => ["native:#{for_platform}"]
        end
      end
    end

    def extconf
      "#{@ext_dir}/#{@config_script}"
    end


    def make
      unless @make
        @make =
          if RUBY_PLATFORM =~ /mswin/ then
            'nmake'
          else
            ENV['MAKE'] || %w[gmake make].find { |c| system(c, '-v') }
          end
      end
      @make
    end

    def binary(platform = nil)
      ext = case platform
        when /darwin/
          'bundle'
        when /mingw|mswin|linux/
          'so'
        when /java/
          'jar'
        else
          RbConfig::CONFIG['DLEXT']
      end
      "#{@name}.#{ext}"
    end

    def source_files
     @source_files ||= FileList["#{@ext_dir}/#{@source_pattern}"]
    end

    def compiles_cross_platform
      [*@cross_platform].map { |p| "compile:#{p}" }
    end

    def natives_cross_platform
      [*@cross_platform].map { |p| "native:#{p}" }
    end

    def fake_rb(version)
      <<-FAKE_RB
        class Object
          remove_const :RUBY_PLATFORM
          remove_const :RUBY_VERSION
          RUBY_PLATFORM = "i386-mingw32"
          RUBY_VERSION = "#{version}"
        end
FAKE_RB
    end

    def java_source_files
      @java_source_files ||= FileList["#{@java_ext_dir}/**/*.java"]
    end

    #
    # Discover Java Extension Directories and build an extdirs argument
    #
    def java_extdirs_arg
      extdirs = Java::java.lang.System.getProperty('java.ext.dirs') rescue nil
      extdirs = ENV['JAVA_EXT_DIR'] unless extdirs
      java_extdir = extdirs.nil? ? "" : "-extdirs \"#{extdirs}\""
    end

    #
    # Discover the Java/JRuby classpath and build a classpath argument
    #
    # @params
    #   *args:: Additional classpath arguments to append
    #
    # Copied verbatim from the ActiveRecord-JDBC project. There are a small myriad
    # of ways to discover the Java classpath correctly.
    #
    def java_classpath_arg(*args)
      if RUBY_PLATFORM =~ /java/
        begin
          cpath  = Java::java.lang.System.getProperty('java.class.path').split(File::PATH_SEPARATOR)
          cpath += Java::java.lang.System.getProperty('sun.boot.class.path').split(File::PATH_SEPARATOR)
          jruby_cpath = cpath.compact.join(File::PATH_SEPARATOR)
        rescue => e
        end
      end
      unless jruby_cpath
        jruby_cpath = ENV['JRUBY_PARENT_CLASSPATH'] || ENV['JRUBY_HOME'] &&
          FileList["#{ENV['JRUBY_HOME']}/lib/*.jar"].join(File::PATH_SEPARATOR)
      end
      raise "JRUBY_HOME or JRUBY_PARENT_CLASSPATH are not set" unless jruby_cpath
      jruby_cpath += File::PATH_SEPARATOR + args.join(File::PATH_SEPARATOR) unless args.empty?
      jruby_cpath ? "-cp \"#{jruby_cpath}\"" : ""
    end

  end
end
