// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2025 & onwards, Predidit.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#ifndef D3D11_RENDERER_H_
#define D3D11_RENDERER_H_

#include <Windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <dxgi1_5.h>
#include <wrl.h>

#include <array>
#include <cstdint>
#include <functional>
#include <iostream>

#include "utils.h"

// |D3D11Renderer| provides an abstraction around Direct3D 11 for video
// rendering with libmpv's native DXGI support.
// This replaces the previous ANGLE-based implementation with a simpler,
// more efficient approach using mpv's built-in D3D11 renderer.

class D3D11Renderer {
 public:
  const int32_t width() const { return width_; }
  const int32_t height() const { return height_; }
  const HANDLE handle() const { return handle_; }
  ID3D11Device* device() const { return d3d_11_device_; }
  IDXGISwapChain* swap_chain() const { return swap_chain_; }

  D3D11Renderer(int32_t width, int32_t height);

  ~D3D11Renderer();

  bool SetSize(int32_t width, int32_t height);

  void CopyTexture();

 private:
  bool CreateD3D11Device();

  bool CreateTexture();

  void CleanUp(bool release_device);

  int32_t width_ = 1;
  int32_t height_ = 1;
  HANDLE handle_ = nullptr;

  // Sync operations.
  HANDLE mutex_ = nullptr;

  // D3D 11
  ID3D11Device* d3d_11_device_ = nullptr;
  ID3D11DeviceContext* d3d_11_device_context_ = nullptr;
  IDXGISwapChain* swap_chain_ = nullptr;

  // GPU completion fence used to synchronize the per-frame CopyResource on
  // this device with the consumer (Flutter Engine) device. Without it, the
  // legacy D3D11_RESOURCE_MISC_SHARED handle has no implicit cross-device
  // synchronization and the consumer can sample a partially written texture,
  // producing block-shaped tearing / flicker.
  Microsoft::WRL::ComPtr<ID3D11Query> copy_complete_query_;

  struct SharedTextureBuffer {
    Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
    HANDLE handle = nullptr;
  };

  static constexpr size_t kSharedTextureBufferCount = 3;
  std::array<SharedTextureBuffer, kSharedTextureBufferCount> shared_textures_;
  size_t active_shared_texture_index_ = 0;

  static int instance_count_;
};

#endif
