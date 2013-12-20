# Copyright (c) 2012, HipByte SPRL and contributors
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
# 
# 1. Redistributions of source code must retain the above copyright notice, this
#    list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

require 'motion/project/app'

App = Motion::Project::App
App.template = :ios

require 'motion/project'
require 'motion/project/template/ios/config'
require 'motion/project/template/ios/builder'

desc "Build the project, then run the simulator"
task :default => :simulator

desc "Build everything"
task :build => ['build:simulator', 'build:device']

namespace :build do
  desc "Build the simulator version"
  task :simulator do
    # TODO: Ensure Info.plist gets regenerated on each build so it has ints for
    # Instruments and strings for normal builds.
    rm_f File.join(App.config.app_bundle('iPhoneSimulator'), 'Info.plist')

    App.build('iPhoneSimulator')
  end

  desc "Build the device version"
  task :device do
    # TODO: Ensure Info.plist gets regenerated on each build so it has ints for
    # Instruments and strings for normal builds.
    rm_f File.join(App.config.app_bundle('iPhoneOS'), 'Info.plist')

    App.build('iPhoneOS')
    App.codesign('iPhoneOS')
  end
end

desc "Run the simulator"
task :simulator do
  unless ENV["skip_build"]
    Rake::Task["build:simulator"].invoke
  end
  app = App.config.app_bundle('iPhoneSimulator')
  target = ENV['target'] || App.config.sdk_version

  if ENV['TMUX']
    tmux_default_command = `tmux show-options -g default-command`.strip
    unless tmux_default_command.include?("reattach-to-user-namespace")
      App.warn(<<END

    It appears you are using tmux without 'reattach-to-user-namespace', the simulator might not work properly. You can either disable tmux or run the following commands:

      $ brew install reattach-to-user-namespace
      $ echo 'set-option -g default-command "reattach-to-user-namespace -l $SHELL"' >> ~/.tmux.conf

END
      )
    end
  end

  # Cleanup the simulator application sandbox, to avoid having old resource files there.
  if ENV['clean']
    sim_apps = File.expand_path("~/Library/Application Support/iPhone Simulator/#{target}/Applications")
    Dir.glob("#{sim_apps}/**/*.app").each do |app_bundle|
      if File.basename(app_bundle) == File.basename(app)
        rm_rf File.dirname(app_bundle)
        break
      end  
    end
  end

  # Prepare the device info.
  family_int =
    if family = ENV['device_family']
      App.config.device_family_int(family.downcase.intern)
    else
      App.config.device_family_ints[0]
    end
  retina = ENV['retina']
  simulate_device = App.config.device_family_string(family_int, target, retina)

  # Launch the simulator.
  xcode = App.config.xcode_dir
  env = "DYLD_FRAMEWORK_PATH=\"#{xcode}/../Frameworks\":\"#{xcode}/../OtherFrameworks\""
  env << ' SIM_SPEC_MODE=1' if App.config.spec_mode
  sim = File.join(App.config.bindir, 'ios/sim')
  debug = (ENV['debug'] ? 1 : (App.config.spec_mode ? '0' : '2'))
  app_args = (ENV['args'] or '')
  App.info 'Simulate', app
  at_exit { system("stty echo") } if $stdout.tty? # Just in case the simulator launcher crashes and leaves the terminal without echo.
  Signal.trap(:INT) { } if ENV['debug']
  system "#{env} #{sim} #{debug} #{family_int} '#{simulate_device}' #{target} \"#{xcode}\" \"#{app}\" #{app_args}"
  App.config.print_crash_message if $?.exitstatus != 0 && !App.config.spec_mode
  exit($?.exitstatus)
end

desc "Create an .ipa archive"
task :archive => ['build:device'] do
  App.archive
end

namespace :archive do
  desc "Create an .ipa archive for distribution (AppStore)"
  task :distribution do
    App.config_without_setup.build_mode = :release
    App.config_without_setup.distribution_mode = true
    Rake::Task["archive"].invoke
  end
end

desc "Same as 'spec:simulator'"
task :spec => ['spec:simulator']

namespace :spec do
  desc "Run the test/spec suite on the simulator"
  task :simulator do
    App.config_without_setup.spec_mode = true
    Rake::Task["simulator"].invoke
  end

  desc "Run the test/spec suite on the device"
  task :device do
    App.config_without_setup.spec_mode = true
    ENV['debug'] ||= '1'
    Rake::Task["device"].invoke
  end
end

$deployed_app_path = nil

desc "Deploy on the device"
task :device => :archive do
  App.info 'Deploy', App.config.archive
  device_id = (ENV['id'] or App.config.device_id)
  unless App.config.provisioned_devices.include?(device_id)
    App.fail "Device ID `#{device_id}' not provisioned in profile `#{App.config.provisioning_profile}'"
  end
  env = "XCODE_DIR=\"#{App.config.xcode_dir}\""
  deploy = File.join(App.config.bindir, 'ios/deploy')
  flags = Rake.application.options.trace ? '-d' : ''
  Signal.trap(:INT) { } if ENV['debug']
  cmd = "#{env} #{deploy} #{flags} \"#{device_id}\" \"#{App.config.archive}\""
  if ENV['install_only']
    $deployed_app_path = `#{cmd}`.strip
  else
    sh(cmd)
  end
end

desc "Create a .a static library"
task :static do
  libs = %w{iPhoneSimulator iPhoneOS}.map do |platform|
    '"' + App.build(platform, :static => true) + '"'
  end
  fat_lib = File.join(App.config.build_dir, App.config.name + '-universal.a')
  App.info 'Create', fat_lib
  sh "/usr/bin/lipo -create #{libs.join(' ')} -output \"#{fat_lib}\""
end

IOS_SIM_INSTRUMENTS_TEMPLATES = [
  'Allocations', 'Leaks', 'Activity Monitor',
  'Zombies', 'Time Profiler', 'System Trace', 'Automation',
  'File Activity', 'Core Data'
]

IOS_DEVICE_INSTRUMENTS_TEMPLATES = [
  'Allocations', 'Leaks', 'Activity Monitor',
  'Zombies', 'Time Profiler', 'System Trace', 'Automation',
  'Energy Diagnostics', 'Network', 'System Usage', 'Core Animation',
  'OpenGL ES Driver', 'OpenGL ES Analysis'
]

desc "Same as profile:simulator"
task :profile => ['profile:simulator']

namespace :profile do
  desc "Run a build on the simulator through Instruments"
  task :simulator do
    ENV['__USE_DEVICE_INT__'] = '1'
    Rake::Task['build:simulator'].invoke

    plist = App.config.profiler_config_plist('iPhoneSimulator', ENV['args'], ENV['template'], IOS_SIM_INSTRUMENTS_TEMPLATES)
    plist['com.apple.xcode.simulatedDeviceFamily'] = App.config.device_family_ints.first
    plist['com.apple.xcode.SDKPath'] = App.config.sdk('iPhoneSimulator')
    plist['optionalData']['launchOptions']['architectureType'] = 0
    plist['deviceIdentifier'] = App.config.sdk('iPhoneSimulator')
    App.profile('iPhoneSimulator', plist)
  end

  namespace :simulator do
    desc 'List all built-in iOS Simulator Instruments templates'
    task :templates do
      puts "Built-in iOS Simulator Instruments templates:"
      IOS_SIM_INSTRUMENTS_TEMPLATES.each do |template|
        puts "* #{template}"
      end
    end
  end

  desc "Run a build on the device through Instruments"
  task :device do
    ENV['__USE_DEVICE_INT__'] = '1'

    # Create a build that allows debugging but doesn’t start a debugger on deploy.
    App.config.entitlements['get-task-allow'] = true
    ENV['install_only'] = '1'
    Rake::Task['device'].invoke

    if $deployed_app_path.nil? || $deployed_app_path.empty?
      App.fail 'Unable to determine remote app path'
    end

    plist = App.config.profiler_config_plist('iPhoneOS', ENV['args'], ENV['template'], IOS_DEVICE_INSTRUMENTS_TEMPLATES, false)
    plist['absolutePathOfLaunchable'] = File.join($deployed_app_path, App.config.bundle_name)
    plist['deviceIdentifier'] = (ENV['id'] or App.config.device_id)
    App.profile('iPhoneOS', plist)
  end

  namespace :device do
    desc 'List all built-in iOS device Instruments templates'
    task :templates do
      puts "Built-in iOS device Instruments templates:"
      IOS_DEVICE_INSTRUMENTS_TEMPLATES.each do |template|
        puts "* #{template}"
      end
    end
  end
end

