// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2025 & onwards, Predidit.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "d3d11_renderer.h"

#include <iostream>

#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3d11.lib")

#define FAIL(message)                                           \
  std::cout << "media_kit: D3D11Renderer: Failure: " << message \
            << std::endl;                                       \
  return false

#define CHECK_HRESULT(message) \
  if (FAILED(hr)) {            \
    FAIL(message);             \
  }

int D3D11Renderer::instance_count_ = 0;

D3D11Renderer::D3D11Renderer(int32_t width, int32_t height)
    : width_(width), height_(height) {
  mutex_ = ::CreateMutex(NULL, FALSE, NULL);
  if (!CreateD3D11Device()) {
    throw std::runtime_error("Unable to create Direct3D 11 device.");
  }
  if (!CreateTexture()) {
    throw std::runtime_error("Unable to create Direct3D 11 texture.");
  }
  instance_count_++;
}

D3D11Renderer::~D3D11Renderer() {
  CleanUp(true);
  ::ReleaseMutex(mutex_);
  ::CloseHandle(mutex_);
  instance_count_--;
}

bool D3D11Renderer::SetSize(int32_t width, int32_t height) {
  if (width == width_ && height == height_) {
    return true;
  }

  auto previous_width = width_;
  auto previous_height = height_;

  // Drain any in-flight GPU work that might still be reading the back buffer
  // or writing to the shared texture ring before we tear them down. Releasing
  // resources while their commands are still queued on the GPU can cause the
  // next frame to display a partially valid surface (resize-time flicker).
  if (d3d_11_device_context_ != nullptr && copy_complete_query_) {
    d3d_11_device_context_->End(copy_complete_query_.Get());
    d3d_11_device_context_->Flush();
    BOOL done = FALSE;
    while (d3d_11_device_context_->GetData(copy_complete_query_.Get(), &done,
                                           sizeof(done), 0) == S_FALSE) {
      ::SwitchToThread();
    }
  }

  for (auto& shared_texture : shared_textures_) {
    shared_texture.texture.Reset();
    shared_texture.handle = nullptr;
  }
  active_shared_texture_index_ = 0;
  handle_ = nullptr;

  if (d3d_11_device_context_ != nullptr) {
    d3d_11_device_context_->ClearState();
    d3d_11_device_context_->Flush();
  }

  // Resize the swap chain (this will resize the back buffer)
  if (swap_chain_) {
    auto hr = swap_chain_->ResizeBuffers(0, width, height, DXGI_FORMAT_UNKNOWN,
                                         0);
    if (FAILED(hr)) {
      std::cout << "media_kit: D3D11Renderer: Failed to resize swap chain: 0x"
                << std::hex << static_cast<unsigned long>(hr) << std::dec
                << std::endl;
      width_ = previous_width;
      height_ = previous_height;
      return CreateTexture();
    }
  }

  width_ = width;
  height_ = height;

  // Recreate the shared texture with the new size
  return CreateTexture();
}

void D3D11Renderer::CopyTexture() {
  ::WaitForSingleObject(mutex_, INFINITE);

  // With native DXGI rendering, mpv renders directly to the swap chain's back buffer.
  // We need to copy the back buffer to our shared texture for Flutter.
  if (d3d_11_device_context_ != nullptr && swap_chain_ != nullptr) {
    // Get the back buffer from the swap chain
    Microsoft::WRL::ComPtr<ID3D11Texture2D> back_buffer;
    auto hr = swap_chain_->GetBuffer(0, __uuidof(ID3D11Texture2D),
                                     (void**)&back_buffer);
    auto next_index =
        (active_shared_texture_index_ + 1) % shared_textures_.size();
    auto& shared_texture = shared_textures_[next_index];
    if (SUCCEEDED(hr) && back_buffer && shared_texture.texture) {
      // Copy from back buffer to shared texture
      d3d_11_device_context_->CopyResource(shared_texture.texture.Get(),
                                           back_buffer.Get());

      // The shared texture is created with the legacy
      // D3D11_RESOURCE_MISC_SHARED flag (no keyed mutex / NT handle), which
      // gives the consumer device (Flutter Engine) no implicit synchronization
      // against our writes. We must therefore drain the GPU before publishing
      // the handle, otherwise Flutter may sample mid-copy and show block-shaped
      // garbage / flicker. This mirrors the glFinish() previously performed by
      // the ANGLE-based implementation.
      if (copy_complete_query_) {
        d3d_11_device_context_->End(copy_complete_query_.Get());
        d3d_11_device_context_->Flush();
        BOOL done = FALSE;
        while (d3d_11_device_context_->GetData(copy_complete_query_.Get(),
                                               &done, sizeof(done), 0) ==
               S_FALSE) {
          ::SwitchToThread();
        }
      } else {
        d3d_11_device_context_->Flush();
      }

      active_shared_texture_index_ = next_index;
      handle_ = shared_texture.handle;
    }
  }

  ::ReleaseMutex(mutex_);
}

void D3D11Renderer::CleanUp(bool release_device) {
  // Release texture
  for (auto& shared_texture : shared_textures_) {
    shared_texture.texture.Reset();
    shared_texture.handle = nullptr;
  }
  active_shared_texture_index_ = 0;
  handle_ = nullptr;

  // Release swap chain
  if (swap_chain_) {
    swap_chain_->Release();
    swap_chain_ = nullptr;
  }

  // Release device and context if the instance is being destroyed
  if (release_device) {
    copy_complete_query_.Reset();
    if (d3d_11_device_context_) {
      d3d_11_device_context_->Release();
      d3d_11_device_context_ = nullptr;
    }
    if (d3d_11_device_) {
      d3d_11_device_->Release();
      d3d_11_device_ = nullptr;
    }
  }
}

bool D3D11Renderer::CreateD3D11Device() {
  if (d3d_11_device_ != nullptr) {
    return true;  // Already created
  }

  const D3D_FEATURE_LEVEL feature_levels[] = {
      D3D_FEATURE_LEVEL_11_1,
      D3D_FEATURE_LEVEL_11_0,
      D3D_FEATURE_LEVEL_10_1,
      D3D_FEATURE_LEVEL_10_0,
      D3D_FEATURE_LEVEL_9_3,
  };

  IDXGIAdapter1* adapter = nullptr;
  D3D_DRIVER_TYPE driver_type = D3D_DRIVER_TYPE_UNKNOWN;
  UINT creation_flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;

  // Automatically selecting adapter on Windows 10 RTM or greater
  if (Utils::IsWindows10RTMOrGreater()) {
    adapter = nullptr;
    driver_type = D3D_DRIVER_TYPE_HARDWARE;
  } else {
    IDXGIFactory1* dxgi = nullptr;
    ::CreateDXGIFactory1(__uuidof(IDXGIFactory1), (void**)&dxgi);
    if (dxgi) {
      dxgi->EnumAdapters1(0, &adapter);
      dxgi->Release();
    }
  }

  auto hr = ::D3D11CreateDevice(
      adapter, driver_type, 0, creation_flags, feature_levels,
      sizeof(feature_levels) / sizeof(D3D_FEATURE_LEVEL), D3D11_SDK_VERSION,
      &d3d_11_device_, nullptr, &d3d_11_device_context_);

  CHECK_HRESULT("D3D11CreateDevice");

  Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device;
  hr = d3d_11_device_->QueryInterface(IID_PPV_ARGS(&dxgi_device));
  CHECK_HRESULT("ID3D11Device::QueryInterface<IDXGIDevice>");

  Microsoft::WRL::ComPtr<IDXGIAdapter> dxgi_adapter;
  hr = dxgi_device->GetAdapter(&dxgi_adapter);
  CHECK_HRESULT("IDXGIDevice::GetAdapter");

  Microsoft::WRL::ComPtr<IDXGIFactory2> dxgi_factory2;
  hr = dxgi_adapter->GetParent(IID_PPV_ARGS(&dxgi_factory2));

  if (SUCCEEDED(hr) && dxgi_factory2) {
    DXGI_SWAP_CHAIN_DESC1 swap_chain_desc = {};
    swap_chain_desc.Width = width_;
    swap_chain_desc.Height = height_;
    swap_chain_desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    swap_chain_desc.SampleDesc.Count = 1;
    swap_chain_desc.BufferUsage =
        DXGI_USAGE_RENDER_TARGET_OUTPUT | DXGI_USAGE_SHADER_INPUT;
    swap_chain_desc.BufferCount = 2;
    swap_chain_desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    swap_chain_desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;

    Microsoft::WRL::ComPtr<IDXGISwapChain1> swap_chain_1;
    hr = dxgi_factory2->CreateSwapChainForComposition(
        d3d_11_device_, &swap_chain_desc, nullptr, &swap_chain_1);
    CHECK_HRESULT("IDXGIFactory2::CreateSwapChainForComposition");

    hr = swap_chain_1->QueryInterface(IID_PPV_ARGS(&swap_chain_));
    CHECK_HRESULT("IDXGISwapChain1::QueryInterface<IDXGISwapChain>");
  } else {
    Microsoft::WRL::ComPtr<IDXGIFactory1> dxgi_factory1;
    hr = dxgi_adapter->GetParent(IID_PPV_ARGS(&dxgi_factory1));
    CHECK_HRESULT("IDXGIAdapter::GetParent<IDXGIFactory1>");

    DXGI_SWAP_CHAIN_DESC swap_chain_desc = {};
    swap_chain_desc.BufferDesc.Width = width_;
    swap_chain_desc.BufferDesc.Height = height_;
    swap_chain_desc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    swap_chain_desc.BufferDesc.RefreshRate.Numerator = 0;
    swap_chain_desc.BufferDesc.RefreshRate.Denominator = 1;
    swap_chain_desc.SampleDesc.Count = 1;
    swap_chain_desc.BufferUsage =
        DXGI_USAGE_RENDER_TARGET_OUTPUT | DXGI_USAGE_SHADER_INPUT;
    swap_chain_desc.BufferCount = 1;
    swap_chain_desc.OutputWindow = ::GetDesktopWindow();
    swap_chain_desc.Windowed = TRUE;
    swap_chain_desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    hr = dxgi_factory1->CreateSwapChain(d3d_11_device_, &swap_chain_desc,
                                        &swap_chain_);
    CHECK_HRESULT("IDXGIFactory1::CreateSwapChain");
  }

  auto dxgi_device_success = d3d_11_device_->QueryInterface(
      __uuidof(IDXGIDevice), (void**)&dxgi_device);
  if (SUCCEEDED(dxgi_device_success) && dxgi_device != nullptr) {
    dxgi_device->SetGPUThreadPriority(5);  // Must be in interval [-7, 7]
  }

  auto level = d3d_11_device_->GetFeatureLevel();
  std::cout << "media_kit: D3D11Renderer: Direct3D Feature Level: "
            << (((unsigned)level) >> 12) << "_"
            << ((((unsigned)level) >> 8) & 0xf) << std::endl;

  // Create the GPU completion event query used by CopyTexture() to drain the
  // command queue before publishing the shared texture handle to Flutter.
  D3D11_QUERY_DESC query_desc = {};
  query_desc.Query = D3D11_QUERY_EVENT;
  query_desc.MiscFlags = 0;
  hr = d3d_11_device_->CreateQuery(&query_desc, &copy_complete_query_);
  CHECK_HRESULT("ID3D11Device::CreateQuery(D3D11_QUERY_EVENT)");

  if (adapter) {
    adapter->Release();
  }

  return true;
}

bool D3D11Renderer::CreateTexture() {
  for (auto& shared_texture : shared_textures_) {
    shared_texture.texture.Reset();
    shared_texture.handle = nullptr;
  }

  // Create shared textures for Flutter rendering.
  // Using a small ring buffer avoids reading and writing the same shared
  // surface concurrently across mpv and Flutter.
  for (size_t index = 0; index < shared_textures_.size(); ++index) {
    D3D11_TEXTURE2D_DESC texture_desc = {0};
    texture_desc.Width = width_;
    texture_desc.Height = height_;
    texture_desc.MipLevels = 1;
    texture_desc.ArraySize = 1;
    texture_desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    texture_desc.SampleDesc.Count = 1;
    texture_desc.SampleDesc.Quality = 0;
    texture_desc.Usage = D3D11_USAGE_DEFAULT;
    texture_desc.BindFlags =
        D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    texture_desc.CPUAccessFlags = 0;
    texture_desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;

    auto hr = d3d_11_device_->CreateTexture2D(
        &texture_desc, nullptr, &shared_textures_[index].texture);
    CHECK_HRESULT("ID3D11Device::CreateTexture2D");

    Microsoft::WRL::ComPtr<IDXGIResource> resource;
    hr = shared_textures_[index].texture.As(&resource);
    CHECK_HRESULT("ID3D11Texture2D::As<IDXGIResource>");

    // Retrieve the shared HANDLE for interop with Flutter.
    hr = resource->GetSharedHandle(&shared_textures_[index].handle);
    CHECK_HRESULT("IDXGIResource::GetSharedHandle");
  }

  active_shared_texture_index_ = 0;
  handle_ = shared_textures_[active_shared_texture_index_].handle;

  return true;
}
