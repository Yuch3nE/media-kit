#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint media_kit_video.podspec` to validate before publishing.
#

require_relative '../common/darwin/Podspec/media_kit_utils.rb'

Pod::Spec.new do |s|
  # Setup required files
  system("make -C ../common/darwin HEADERS_DESTDIR=\"$(pwd)/Headers\"")

  # Initialize `MediaKitUtils`
  mku = MediaKitUtils.new(MediaKitUtils::Platform::MACOS)

  s.name             = 'media_kit_video'
  s.version          = '0.0.1'
  s.summary          = 'Native implementation for video playback in package:media_kit'
  s.description      = <<-DESC
  Native implementation for video playback in package:media_kit.
                       DESC
  s.homepage         = 'https://github.com/media-kit/media-kit.git'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Hitesh Kumar Saini' => 'saini123hitesh@gmail.com' }

  s.source           = { :path => '.' }
  s.platform         = :osx, '14.0'
  s.swift_version    = '5.0'
  s.dependency         'FlutterMacOS'

  if mku.libs_found
    # Define paths to frameworks dir
    framework_search_paths_macosx = sprintf('$(PROJECT_DIR)/../Flutter/ephemeral/.symlinks/plugins/%s/macos/Frameworks/.symlinks/mpv/macos', mku.libs_package)
    source_files = [
      'Classes/plugin/common/**/*.swift',
      'Classes/plugin/gl/**/*.swift',
      'Classes/plugin/TextureHW.swift',
      'Classes/plugin/Utils.swift',
      'Headers/**/*.h',
    ]
    public_header_files = ['Headers/**/*.h']
    swift_flags = ['$(inherited)']

    vulkan_sdk_prefix = [
      ENV['VULKAN_SDK_PREFIX'],
      '/opt/homebrew',
      '/usr/local',
    ].compact.find do |prefix|
      File.exist?(File.join(prefix, 'include', 'vulkan', 'vulkan.h'))
    end

    if vulkan_sdk_prefix
      source_files += [
        'Classes/plugin/TextureVK.swift',
        'Classes/plugin/vulkan/MediaKitVulkanShim.h',
        'Classes/plugin/vulkan/MediaKitVulkanShim.mm',
      ]
      public_header_files += ['Classes/plugin/vulkan/MediaKitVulkanShim.h']
      swift_flags << '-DMEDIA_KIT_ENABLE_VULKAN'
    end

    header_search_paths = ['"$(inherited)"']
    library_search_paths = ['"$(inherited)"']
    if vulkan_sdk_prefix
      header_search_paths << "\"#{vulkan_sdk_prefix}/include\""
      library_search_paths << "\"#{vulkan_sdk_prefix}/lib\""
    end
    header_search_paths += ['"/opt/homebrew/include"', '"/usr/local/include"']
    library_search_paths += ['"/opt/homebrew/lib"', '"/usr/local/lib"']

    s.source_files = source_files
    s.public_header_files = public_header_files
    s.private_header_files = []
    s.libraries           = ['c++']
    s.weak_frameworks     = ['Metal', 'QuartzCore']
    s.pod_target_xcconfig = {
      'DEFINES_MODULE'                      => 'YES',
      'CLANG_ENABLE_MODULES'                => 'YES',
      'GCC_WARN_INHIBIT_ALL_WARNINGS'       => 'YES',
      'GCC_PREPROCESSOR_DEFINITIONS'        => '"$(inherited)" GL_SILENCE_DEPRECATION COREVIDEO_SILENCE_GL_DEPRECATION VK_USE_PLATFORM_METAL_EXT=1',
      'FRAMEWORK_SEARCH_PATHS[sdk=macosx*]' => sprintf('"$(inherited)" "%s"', framework_search_paths_macosx),
      'HEADER_SEARCH_PATHS'                 => header_search_paths.join(' '),
      'LIBRARY_SEARCH_PATHS'                => library_search_paths.join(' '),
      'OTHER_LDFLAGS'                       => '"$(inherited)" -framework Mpv',
      'OTHER_SWIFT_FLAGS'                   => swift_flags.join(' '),
    }
  else
    s.source_files        = 'Classes/stub/**/*.swift'
    s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  end
end
