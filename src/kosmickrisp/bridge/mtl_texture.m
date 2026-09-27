/*
 * Copyright 2025 LunarG, Inc.
 * Copyright 2025 Google LLC
 * SPDX-License-Identifier: MIT
 */

#include "mtl_texture.h"

/* TODO_LUNARG Remove */
#include "kk_image_layout.h"

/* TODO_LUNARG Remove */
#include "vulkan/vulkan.h"

#include <Metal/MTLTexture.h>

uint64_t
mtl_texture_get_gpu_resource_id(mtl_texture *texture)
{
   @autoreleasepool {
      id<MTLTexture> tex = (id<MTLTexture>)texture;
      return (uint64_t)[tex gpuResourceID]._impl;
   }
}

/* TODO_KOSMICKRISP This should be part of the mapping */
static uint32_t
mtl_texture_view_type(uint32_t type, uint8_t sample_count)
{
   switch (type) {
   case VK_IMAGE_VIEW_TYPE_1D:
      return MTLTextureType1D;
   case VK_IMAGE_VIEW_TYPE_1D_ARRAY:
      return MTLTextureType1DArray;
   case VK_IMAGE_VIEW_TYPE_2D:
      return sample_count > 1u ? MTLTextureType2DMultisample : MTLTextureType2D;;
   case VK_IMAGE_VIEW_TYPE_CUBE:
      return MTLTextureTypeCube;
   case VK_IMAGE_VIEW_TYPE_CUBE_ARRAY:
      return MTLTextureTypeCubeArray;
   case VK_IMAGE_VIEW_TYPE_2D_ARRAY:
      return sample_count > 1u ? MTLTextureType2DMultisampleArray : MTLTextureType2DArray;
   case VK_IMAGE_VIEW_TYPE_3D:
      return MTLTextureType3D;
   default:
      assert(false && "Unsupported VkViewType");
      return MTLTextureType1D;
   }
}

static MTLTextureSwizzle
mtl_texture_swizzle(enum pipe_swizzle swizzle)
{
   const MTLTextureSwizzle map[] =
      {
         [PIPE_SWIZZLE_X] = MTLTextureSwizzleRed,
         [PIPE_SWIZZLE_Y] = MTLTextureSwizzleGreen,
         [PIPE_SWIZZLE_Z] = MTLTextureSwizzleBlue,
         [PIPE_SWIZZLE_W] = MTLTextureSwizzleAlpha,
         [PIPE_SWIZZLE_0] = MTLTextureSwizzleZero,
         [PIPE_SWIZZLE_1] = MTLTextureSwizzleOne,
      };

   return map[swizzle];
}

static uint32_t
mtl_pixel_format_cast_class(MTLPixelFormat fmt)
{
   switch ((uint32_t)fmt) {
   case 1: case 10: case 11: case 12: case 13: case 14:
      return 1; /* 8-bit normal */
   case 20: case 22: case 23: case 24: case 25:
   case 30: case 31: case 32: case 33: case 34:
   case 40: case 41: case 42: case 43:
      return 2; /* 16-bit normal & packed */
   case 53: case 54: case 55:
   case 60: case 62: case 63: case 64: case 65:
   case 70: case 71: case 72: case 73: case 74:
   case 80: case 81:
   case 90: case 91: case 92: case 93: case 94:
      return 4; /* 32-bit normal & packed */
   case 103: case 104: case 105:
   case 110: case 112: case 113: case 114: case 115:
      return 6; /* 64-bit normal */
   case 123: case 124: case 125:
      return 8; /* 128-bit normal */
   case 130: case 131: return 9;  /* BC1 */
   case 132: case 133: return 10; /* BC2 */
   case 134: case 135: return 11; /* BC3 */
   case 140: case 141: return 12; /* BC4 */
   case 142: case 143: return 13; /* BC5 */
   case 150: case 151: return 14; /* BC6H */
   case 152: case 153: return 15; /* BC7 */
   case 170: case 172: return 20; /* EAC R11 */
   case 174: case 176: return 21; /* EAC RG11 */
   case 178: case 179: return 22; /* EAC RGBA8 */
   case 180: case 181: return 23; /* ETC2 RGB8 */
   case 182: case 183: return 24; /* ETC2 RGB8A1 */
   case 255: case 262: return 41; /* D24S8 / X24S8 */
   case 260: case 261: return 42; /* D32FS8 / X32S8 */
   case 552: case 553: return 43; /* BGRA10_XR */
   case 554: case 555: return 44; /* BGR10_XR */
   default:
      return 0;
   }
}

static void
mtl_sanitize_texture_view_args(id<MTLTexture> tex, MTLPixelFormat *format,
                               MTLTextureType *type, NSRange *levels,
                               NSRange *slices)
{
   MTLPixelFormat src_format = [tex pixelFormat];
   if (*format != src_format) {
      uint32_t src_class = mtl_pixel_format_cast_class(src_format);
      uint32_t dst_class = mtl_pixel_format_cast_class(*format);
      if (src_class == 0 || src_class != dst_class)
         *format = src_format;
   }

   NSUInteger max_levels = [tex mipmapLevelCount];
   if (max_levels == 0)
      max_levels = 1;
   if (levels->location >= max_levels)
      levels->location = max_levels - 1;
   if (levels->length == 0)
      levels->length = 1;
   if (levels->location + levels->length > max_levels)
      levels->length = max_levels - levels->location;

   MTLTextureType src_type = [tex textureType];
   NSUInteger max_slices = [tex arrayLength];
   if (src_type == MTLTextureTypeCube ||
       src_type == MTLTextureTypeCubeArray)
      max_slices *= 6;
   if (max_slices == 0)
      max_slices = 1;
   if (slices->location >= max_slices)
      slices->location = max_slices - 1;
   if (slices->length == 0)
      slices->length = 1;
   if (slices->location + slices->length > max_slices)
      slices->length = max_slices - slices->location;

   switch (src_type) {
   case MTLTextureType1D:
   case MTLTextureType1DArray:
      if (*type != MTLTextureType1D && *type != MTLTextureType1DArray)
         *type = slices->length > 1 ? MTLTextureType1DArray : MTLTextureType1D;
      break;
   case MTLTextureType2DMultisample:
   case MTLTextureType2DMultisampleArray:
      if (*type != MTLTextureType2DMultisample &&
          *type != MTLTextureType2DMultisampleArray)
         *type = slices->length > 1 ? MTLTextureType2DMultisampleArray
                                    : MTLTextureType2DMultisample;
      break;
   case MTLTextureType3D:
      *type = MTLTextureType3D;
      break;
   default:
      if ([tex buffer] != nil) {
         *type = MTLTextureType2D;
      } else if (*type != MTLTextureType2D &&
                 *type != MTLTextureType2DArray &&
                 *type != MTLTextureTypeCube &&
                 *type != MTLTextureTypeCubeArray) {
         *type = slices->length > 1 ? MTLTextureType2DArray : MTLTextureType2D;
      }
      break;
   }

   switch (*type) {
   case MTLTextureType1D:
   case MTLTextureType2D:
   case MTLTextureType2DMultisample:
      slices->length = 1;
      break;
   case MTLTextureType3D:
      slices->location = 0;
      slices->length = 1;
      break;
   case MTLTextureTypeCube:
      if (slices->length < 6)
         *type = MTLTextureType2DArray;
      else
         slices->length = 6;
      break;
   case MTLTextureTypeCubeArray:
      if (slices->length < 6)
         *type = MTLTextureType2DArray;
      else
         slices->length -= (slices->length % 6);
      break;
   default:
      break;
   }
}

mtl_texture *
mtl_new_texture_view_with(mtl_texture *texture, const struct kk_view_layout *layout)
{
   @autoreleasepool {
      id<MTLTexture> tex = (id<MTLTexture>)texture;
      if (!tex)
         return nil;
      MTLPixelFormat format = (MTLPixelFormat)layout->format.mtl;
      MTLTextureType type = mtl_texture_view_type(layout->view_type, layout->sample_count_sa);
      NSRange levels = NSMakeRange(layout->base_level, layout->num_levels);
      NSRange slices = NSMakeRange(layout->base_array_layer, layout->array_len);
      mtl_sanitize_texture_view_args(tex, &format, &type, &levels, &slices);
      MTLTextureSwizzleChannels swizzle = MTLTextureSwizzleChannelsMake(mtl_texture_swizzle(layout->swizzle.red),
                                                                        mtl_texture_swizzle(layout->swizzle.green),
                                                                        mtl_texture_swizzle(layout->swizzle.blue),
                                                                        mtl_texture_swizzle(layout->swizzle.alpha));
      return [tex newTextureViewWithPixelFormat:format textureType:type levels:levels slices:slices swizzle:swizzle];
   }
}

mtl_texture *
mtl_new_texture_view_with_no_swizzle(mtl_texture *texture, const struct kk_view_layout *layout)
{
   @autoreleasepool {
      id<MTLTexture> tex = (id<MTLTexture>)texture;
      if (!tex)
         return nil;
      MTLPixelFormat format = (MTLPixelFormat)layout->format.mtl;
      MTLTextureType type = mtl_texture_view_type(layout->view_type, layout->sample_count_sa);
      NSRange levels = NSMakeRange(layout->base_level, layout->num_levels);
      NSRange slices = NSMakeRange(layout->base_array_layer, layout->array_len);
      mtl_sanitize_texture_view_args(tex, &format, &type, &levels, &slices);
      return [tex newTextureViewWithPixelFormat:format textureType:type levels:levels slices:slices];
   }
}

void
mtl_texture_get_bytes(mtl_texture *texture, void *host_ptr,
                      struct mtl_texture_memory_copy *data)
{
   @autoreleasepool {
      id<MTLTexture> tex = (id<MTLTexture>)texture;
      MTLRegion region = MTLRegionMake3D(data->image_origin.x, data->image_origin.y, data->image_origin.z,
                                         data->image_size.x, data->image_size.y, data->image_size.z);
      return [tex getBytes:host_ptr
               bytesPerRow:data->buffer_stride_B
             bytesPerImage:data->buffer_2d_image_size_B
                fromRegion:region
               mipmapLevel:data->image_level
                     slice:data->image_slice];
   }
}

void
mtl_texture_replace_region(mtl_texture *texture, const void *host_ptr,
                           struct mtl_texture_memory_copy *data)
{
   @autoreleasepool {
      id<MTLTexture> tex = (id<MTLTexture>)texture;
      MTLRegion region = MTLRegionMake3D(data->image_origin.x, data->image_origin.y, data->image_origin.z,
                                         data->image_size.x, data->image_size.y, data->image_size.z);
      return [tex replaceRegion:region
                    mipmapLevel:data->image_level
                          slice:data->image_slice
                      withBytes:host_ptr
                    bytesPerRow:data->buffer_stride_B
                  bytesPerImage:data->buffer_2d_image_size_B];
   }
}
