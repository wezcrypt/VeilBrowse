#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerates ios/WezCryptSecureStudio.xcodeproj from the folder layout.
#
#   gem install xcodeproj
#   ruby ios/scripts/generate_xcodeproj.rb [--verbose]
#
# Works on Linux, Windows (Ruby) and macOS; the generated project is committed so
# Xcode / GitHub Actions can build it directly. Re-run after adding or removing files.

require 'fileutils'
require 'optparse'
require 'xcodeproj'

options = { verbose: false }
OptionParser.new do |parser|
  parser.banner = 'Usage: generate_xcodeproj.rb [--verbose]'
  parser.on('-v', '--verbose', 'Print every file added') { options[:verbose] = true }
end.parse!

IOS_ROOT = File.expand_path('..', __dir__)
PROJECT_NAME = 'WezCryptSecureStudio'
PROJECT_PATH = File.join(IOS_ROOT, "#{PROJECT_NAME}.xcodeproj")
DEPLOYMENT_TARGET = '17.0'
BUNDLE_ID = 'com.wezcrypt.securestudio'

def log(message, verbose)
  puts message if verbose
end

abort("Missing sources in #{IOS_ROOT}/#{PROJECT_NAME}") unless Dir.exist?(File.join(IOS_ROOT, PROJECT_NAME))

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH, false, 56)
project.root_object.attributes['ORGANIZATIONNAME'] = 'wezcrypt'
project.root_object.attributes['LastSwiftUpdateCheck'] = '1600'
project.root_object.attributes['LastUpgradeCheck'] = '1600'
project.root_object.development_region = 'en'
project.root_object.known_regions = %w[en Base]

app = project.new_target(:application, PROJECT_NAME, :ios, DEPLOYMENT_TARGET)
unit_tests = project.new_target(:unit_test_bundle, "#{PROJECT_NAME}Tests", :ios, DEPLOYMENT_TARGET)
ui_tests = project.new_target(:ui_test_bundle, "#{PROJECT_NAME}UITests", :ios, DEPLOYMENT_TARGET)
unit_tests.add_dependency(app)
ui_tests.add_dependency(app)

# Adds a folder recursively as groups. Swift files go to the target's Sources
# phase, asset catalogs to Resources; plist/entitlements are referenced only.
def add_folder(project, parent_group, absolute_dir, target, verbose)
  group = parent_group.new_group(File.basename(absolute_dir), File.basename(absolute_dir))
  Dir.children(absolute_dir).sort.each do |entry|
    next if entry.start_with?('.')

    path = File.join(absolute_dir, entry)
    if File.directory?(path) && !entry.end_with?('.xcassets')
      add_folder(project, group, path, target, verbose)
      next
    end
    ref = group.new_reference(entry)
    case File.extname(entry)
    when '.swift'
      target.source_build_phase.add_file_reference(ref, true)
      log("  source   #{path.sub(IOS_ROOT + '/', '')}", verbose)
    when '.xcassets'
      ref.last_known_file_type = 'folder.assetcatalog'
      target.resources_build_phase.add_file_reference(ref, true)
      log("  resource #{path.sub(IOS_ROOT + '/', '')}", verbose)
    else
      log("  ref      #{path.sub(IOS_ROOT + '/', '')}", verbose)
    end
  end
  group
end

add_folder(project, project.main_group, File.join(IOS_ROOT, PROJECT_NAME), app, options[:verbose])
add_folder(project, project.main_group, File.join(IOS_ROOT, "#{PROJECT_NAME}Tests"), unit_tests, options[:verbose])
add_folder(project, project.main_group, File.join(IOS_ROOT, "#{PROJECT_NAME}UITests"), ui_tests, options[:verbose])

common = {
  'IPHONEOS_DEPLOYMENT_TARGET' => DEPLOYMENT_TARGET,
  'SWIFT_VERSION' => '6.0',
  'SWIFT_STRICT_CONCURRENCY' => 'complete',
  'TARGETED_DEVICE_FAMILY' => '1',
  'SUPPORTED_PLATFORMS' => 'iphoneos iphonesimulator',
  'SUPPORTS_MACCATALYST' => 'NO',
  'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD' => 'NO',
  'CODE_SIGN_STYLE' => 'Automatic',
  'DEVELOPMENT_TEAM' => '',
  'MARKETING_VERSION' => '2.1.0',
  'CURRENT_PROJECT_VERSION' => '1',
  'ENABLE_USER_SCRIPT_SANDBOXING' => 'YES',
  'SWIFT_EMIT_LOC_STRINGS' => 'YES',
  'CLANG_ENABLE_MODULES' => 'YES',
  'ENABLE_TESTABILITY' => 'YES'
}

app.build_configurations.each do |config|
  config.build_settings.merge!(common)
  config.build_settings.merge!(
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'PRODUCT_BUNDLE_IDENTIFIER' => BUNDLE_ID,
    'INFOPLIST_FILE' => "#{PROJECT_NAME}/Resources/Info.plist",
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'CODE_SIGN_ENTITLEMENTS' => "#{PROJECT_NAME}/Resources/#{PROJECT_NAME}.entitlements",
    'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
    'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME' => 'AccentColor',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks'],
    'ENABLE_PREVIEWS' => 'YES'
  )
  config.build_settings['SWIFT_COMPILATION_MODE'] = 'wholemodule' if config.name == 'Release'
  config.build_settings['SWIFT_OPTIMIZATION_LEVEL'] = config.name == 'Release' ? '-O' : '-Onone'
  config.build_settings['ENABLE_TESTABILITY'] = 'NO' if config.name == 'Release'
end

unit_tests.build_configurations.each do |config|
  config.build_settings.merge!(common)
  config.build_settings.merge!(
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'PRODUCT_BUNDLE_IDENTIFIER' => "#{BUNDLE_ID}.tests",
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'TEST_HOST' => "$(BUILT_PRODUCTS_DIR)/#{PROJECT_NAME}.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/#{PROJECT_NAME}",
    'BUNDLE_LOADER' => '$(TEST_HOST)',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks']
  )
end

ui_tests.build_configurations.each do |config|
  config.build_settings.merge!(common)
  config.build_settings.merge!(
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'PRODUCT_BUNDLE_IDENTIFIER' => "#{BUNDLE_ID}.uitests",
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'TEST_TARGET_NAME' => PROJECT_NAME,
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks']
  )
end

project.build_configurations.each do |config|
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  config.build_settings['SWIFT_VERSION'] = '6.0'
end

project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.add_test_target(unit_tests)
scheme.add_test_target(ui_tests)
scheme.launch_action.build_configuration = 'Debug'
scheme.test_action.build_configuration = 'Debug'
scheme.archive_action.build_configuration = 'Release'
scheme.save_as(PROJECT_PATH, PROJECT_NAME, true)

sources = app.source_build_phase.files.count
puts "Generated #{PROJECT_PATH} (#{sources} app sources, " \
     "#{unit_tests.source_build_phase.files.count} unit tests, #{ui_tests.source_build_phase.files.count} UI tests)"
