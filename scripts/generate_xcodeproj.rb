#!/usr/bin/env ruby

require "fileutils"
require "pathname"
require "xcodeproj"

ROOT = File.expand_path("..", __dir__)
PROJECT_PATH = File.join(ROOT, "ChatStorage.xcodeproj")
APP_DIR = File.join(ROOT, "ChatStorage")
UNIT_DIR = File.join(ROOT, "ChatStorageTests")
UI_DIR = File.join(ROOT, "ChatStorageUITests")

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes["LastUpgradeCheck"] = "2630"

app = project.new_target(:application, "ChatStorage", :ios, "26.0", nil, :swift)
unit = project.new_target(:unit_test_bundle, "ChatStorageTests", :ios, "26.0", nil, :swift)
ui = project.new_target(:ui_test_bundle, "ChatStorageUITests", :ios, "26.0", nil, :swift)

def set_common_settings(target, bundle_id)
  target.build_configurations.each do |config|
    settings = config.build_settings
    settings["PRODUCT_BUNDLE_IDENTIFIER"] = bundle_id
    settings["IPHONEOS_DEPLOYMENT_TARGET"] = "26.0"
    settings["SWIFT_VERSION"] = "6.0"
    settings["CODE_SIGN_STYLE"] = "Automatic"
    settings["TARGETED_DEVICE_FAMILY"] = "1"
    settings["CLANG_ENABLE_MODULES"] = "YES"
    settings["SWIFT_EMIT_LOC_STRINGS"] = "YES"
  end
end

set_common_settings(app, "com.alibaba.chatstorage.ios")
set_common_settings(unit, "com.alibaba.chatstorage.ios.tests")
set_common_settings(ui, "com.alibaba.chatstorage.ios.uitests")

app.build_configurations.each do |config|
  settings = config.build_settings
  settings["GENERATE_INFOPLIST_FILE"] = "NO"
  settings["INFOPLIST_FILE"] = "ChatStorage/Resources/Info.plist"
  settings["PRODUCT_NAME"] = "ChatStorage"
end

unit.build_configurations.each do |config|
  settings = config.build_settings
  settings["GENERATE_INFOPLIST_FILE"] = "YES"
  settings["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/ChatStorage.app/ChatStorage"
  settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
end

ui.build_configurations.each do |config|
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  config.build_settings["TEST_TARGET_NAME"] = "ChatStorage"
end

project.main_group.new_file("ChatStorage/Resources/Info.plist")

def add_swift_sources(project, target, root_dir)
  Dir.glob(File.join(root_dir, "**", "*.swift")).sort.each do |path|
    relative = Pathname.new(path).relative_path_from(Pathname.new(ROOT)).to_s
    reference = project.main_group.new_file(relative)
    target.add_file_references([reference])
  end
end

add_swift_sources(project, app, APP_DIR)
add_swift_sources(project, unit, UNIT_DIR)
add_swift_sources(project, ui, UI_DIR)

unit.add_dependency(app)
ui.add_dependency(app)

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_build_target(unit, false)
scheme.add_build_target(ui, false)
scheme.add_test_target(unit)
scheme.add_test_target(ui)
scheme.set_launch_target(app)

project.save
scheme.save_as(PROJECT_PATH, "ChatStorage", true)

puts "Generated #{PROJECT_PATH}"
