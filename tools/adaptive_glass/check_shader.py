#!/usr/bin/env python3
"""Execute the production GLSL in Mesa EGL (not a Flutter/Android test).

Uses Python's standard library with Mesa EGL on Linux or Android SDK's bundled
ANGLE on Windows (override its directory with FOLIO_EGL_DIRECTORY). Both engine
target-define configurations are compiled; actual snapshot orientation is also
covered by the on-device Flutter regression. Flutter's runtime-effect include
is replaced only by the equivalent pixel-coordinate function for this harness.
Run from project root: python3 tools/adaptive_glass/check_shader.py
"""
from __future__ import annotations

import ctypes as C
import os
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
W = H = 96


class GPU:
    def __init__(self) -> None:
        if os.name == 'nt':
            sdk = Path(os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
                       or str(Path(os.environ['LOCALAPPDATA']) / 'Android/Sdk'))
            directory = Path(os.environ.get('FOLIO_EGL_DIRECTORY')
                             or sdk / 'emulator/lib64/gles_angle')
            self._dll_directory = os.add_dll_directory(str(directory))
            self.egl = C.CDLL(str(directory / 'libEGL.dll'))
        else:
            self.egl = C.CDLL('libEGL.so.1')
        self.egl.eglGetProcAddress.argtypes = [C.c_char_p]
        self.egl.eglGetProcAddress.restype = C.c_void_p
        get_display = C.CFUNCTYPE(C.c_void_p, C.c_uint, C.c_void_p, C.POINTER(C.c_int))(
            self.egl.eglGetProcAddress(b'eglGetPlatformDisplayEXT'))
        if os.name == 'nt':
            self.egl.eglGetDisplay.argtypes = [C.c_void_p]
            self.egl.eglGetDisplay.restype = C.c_void_p
            self.display = self.egl.eglGetDisplay(None)
        else:
            self.display = get_display(0x31DD, None, None)
        self.e('eglInitialize', C.c_uint, [C.c_void_p, C.c_void_p, C.c_void_p])
        self.e('eglBindAPI', C.c_uint, [C.c_uint])
        self.e('eglChooseConfig', C.c_uint, [C.c_void_p, C.c_void_p, C.c_void_p, C.c_int, C.c_void_p])
        self.e('eglCreateContext', C.c_void_p, [C.c_void_p, C.c_void_p, C.c_void_p, C.c_void_p])
        self.e('eglCreatePbufferSurface', C.c_void_p, [C.c_void_p, C.c_void_p, C.c_void_p])
        self.e('eglMakeCurrent', C.c_uint, [C.c_void_p, C.c_void_p, C.c_void_p, C.c_void_p])
        self.e('eglDestroyContext', C.c_uint, [C.c_void_p, C.c_void_p])
        self.e('eglDestroySurface', C.c_uint, [C.c_void_p, C.c_void_p])
        self.e('eglTerminate', C.c_uint, [C.c_void_p])
        assert self.egl.eglInitialize(self.display, None, None), 'EGL initialization failed'
        assert self.egl.eglBindAPI(0x30A0), 'Cannot select GLES'
        attrib = (C.c_int * 13)(0x3033, 1, 0x3040, 0x0040, 0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3038)
        config, count = C.c_void_p(), C.c_int()
        assert self.egl.eglChooseConfig(self.display, attrib, C.byref(config), 1, C.byref(count))
        assert count.value > 0, 'No GLES3 EGL configuration'
        self.context = self.egl.eglCreateContext(
            self.display, config, None, (C.c_int * 3)(0x3098, 3, 0x3038))
        self.surface = self.egl.eglCreatePbufferSurface(
            self.display, config, (C.c_int * 5)(0x3057, W, 0x3056, H, 0x3038))
        assert self.context and self.surface
        assert self.egl.eglMakeCurrent(self.display, self.surface, self.surface, self.context)
        self.f('glGetString', C.c_char_p, C.c_uint)
        self.f('glCreateShader', C.c_uint, C.c_uint)
        self.f('glShaderSource', None, C.c_uint, C.c_int, C.POINTER(C.c_char_p), C.c_void_p)
        self.f('glCompileShader', None, C.c_uint)
        self.f('glGetShaderiv', None, C.c_uint, C.c_uint, C.POINTER(C.c_int))
        self.f('glGetShaderInfoLog', None, C.c_uint, C.c_int, C.c_void_p, C.c_void_p)
        self.f('glCreateProgram', C.c_uint)
        self.f('glAttachShader', None, C.c_uint, C.c_uint)
        self.f('glLinkProgram', None, C.c_uint)
        self.f('glGetProgramiv', None, C.c_uint, C.c_uint, C.POINTER(C.c_int))
        self.f('glGetProgramInfoLog', None, C.c_uint, C.c_int, C.c_void_p, C.c_void_p)
        self.f('glDeleteShader', None, C.c_uint)
        self.f('glDeleteProgram', None, C.c_uint)
        self.f('glUseProgram', None, C.c_uint)
        self.f('glGenTextures', None, C.c_int, C.POINTER(C.c_uint))
        self.f('glDeleteTextures', None, C.c_int, C.POINTER(C.c_uint))
        self.f('glBindTexture', None, C.c_uint, C.c_uint)
        self.f('glActiveTexture', None, C.c_uint)
        self.f('glTexParameteri', None, C.c_uint, C.c_uint, C.c_int)
        self.f('glTexImage2D', None, C.c_uint, C.c_int, C.c_int, C.c_int, C.c_int, C.c_int, C.c_uint, C.c_uint, C.c_void_p)
        self.f('glGetUniformLocation', C.c_int, C.c_uint, C.c_char_p)
        self.f('glUniform1f', None, C.c_int, C.c_float)
        self.f('glUniform2f', None, C.c_int, C.c_float, C.c_float)
        self.f('glUniform1i', None, C.c_int, C.c_int)
        self.f('glViewport', None, C.c_int, C.c_int, C.c_int, C.c_int)
        self.f('glClearColor', None, C.c_float, C.c_float, C.c_float, C.c_float)
        self.f('glClear', None, C.c_uint)
        self.f('glDrawArrays', None, C.c_uint, C.c_int, C.c_int)
        self.f('glReadPixels', None, C.c_int, C.c_int, C.c_int, C.c_int, C.c_uint, C.c_uint, C.c_void_p)
        self.f('glFinish', None)
        self.f('glDisable', None, C.c_uint)
        self.glDisable(0x0BD0)  # Disable dithering for exact RGBA assertions.
        self.programs = {}
        source = (ROOT / 'assets/shaders/adaptive_glass_foreground.frag').read_text()
        for flipped in (False, True):
            declarations = 'precision highp float;\nprecision highp sampler2D;\n'
            if flipped:
                declarations += '#define IMPELLER_TARGET_OPENGLES 1\n'
            declarations += 'vec4 FlutterFragCoord() { return gl_FragCoord; }\n'
            fragment = source.replace('#include <flutter/runtime_effect.glsl>', declarations)
            self.programs[flipped] = self.program(fragment)
        print('Renderer:', self.glGetString(0x1F01).decode())
        print('GL version:', self.glGetString(0x1F02).decode())

    def e(self, name, restype, args):
        fn = getattr(self.egl, name)
        fn.restype, fn.argtypes = restype, args

    def f(self, name, restype, *args):
        ptr = self.egl.eglGetProcAddress(name.encode())
        if not ptr:
            raise RuntimeError('Missing GL function: ' + name)
        setattr(self, name, C.CFUNCTYPE(restype, *args)(ptr))

    def shader(self, kind, source):
        # The effect uses only GLES 3.0 language features. ANGLE's bundled
        # Windows build supports that version, whereas Mesa accepts 3.2 too.
        if os.name == 'nt':
            source = source.replace('#version 320 es', '#version 300 es')
        obj = self.glCreateShader(kind)
        text = C.c_char_p(source.encode())
        self.glShaderSource(obj, 1, C.byref(text), None)
        self.glCompileShader(obj)
        ok = C.c_int()
        self.glGetShaderiv(obj, 0x8B81, C.byref(ok))
        if not ok.value:
            log = C.create_string_buffer(16384)
            self.glGetShaderInfoLog(obj, len(log), None, log)
            raise AssertionError(log.value.decode())
        return obj

    def program(self, fragment):
        vertex = '''#version 320 es
        precision highp float;
        void main() {
          vec2 p = vec2((gl_VertexID == 1) ? 3.0 : -1.0,
                        (gl_VertexID == 2) ? 3.0 : -1.0);
          gl_Position = vec4(p, 0.0, 1.0);
        }'''
        v, f = self.shader(0x8B31, vertex), self.shader(0x8B30, fragment)
        p = self.glCreateProgram()
        self.glAttachShader(p, v)
        self.glAttachShader(p, f)
        self.glLinkProgram(p)
        self.glDeleteShader(v)
        self.glDeleteShader(f)
        ok = C.c_int()
        self.glGetProgramiv(p, 0x8B82, C.byref(ok))
        if not ok.value:
            log = C.create_string_buffer(16384)
            self.glGetProgramInfoLog(p, len(log), None, log)
            raise AssertionError(log.value.decode())
        return p

    def render(self, background, *, flipped=False, sample=(48, 10),
               origin=(24, 24), x_axis=(32, 0), y_axis=(0, 24),
               opacity=1.0, mask_alpha=255, sigma=0.0):
        p = self.programs[flipped]
        self.glUseProgram(p)
        textures = (C.c_uint * 2)()
        self.glGenTextures(2, textures)
        backdrop = bytes(component for y in range(H) for x in range(W)
                         for component in background(x, y))
        mask = bytes([255, 255, 255, mask_alpha]) * 16
        try:
            for index, (data, width, height) in enumerate(((backdrop, W, H), (mask, 4, 4))):
                self.glActiveTexture(0x84C0 + index)
                self.glBindTexture(0x0DE1, textures[index])
                for parameter in (0x2801, 0x2800):
                    self.glTexParameteri(0x0DE1, parameter, 0x2600)
                for parameter in (0x2802, 0x2803):
                    self.glTexParameteri(0x0DE1, parameter, 0x812F)
                self.glTexImage2D(0x0DE1, 0, 0x1908, width, height, 0, 0x1908, 0x1401, data)
            def loc(name): return self.glGetUniformLocation(p, name.encode())
            det = x_axis[0] * y_axis[1] - y_axis[0] * x_axis[1]
            for name, value in {
                'u_size': (W, H), 'u_mask_origin': origin,
                'u_mask_inverse_x': (y_axis[1] / det, -y_axis[0] / det),
                'u_mask_inverse_y': (-x_axis[1] / det, x_axis[0] / det),
                'u_sample_point': sample,
                'u_mask_blur_uv': (sigma / 32, sigma / 24),
            }.items():
                self.glUniform2f(loc(name), *value)
            self.glUniform1f(loc('u_opacity'), opacity)
            self.glUniform1i(loc('u_backdrop'), 0)
            self.glUniform1i(loc('u_glyph_mask'), 1)
            self.glViewport(0, 0, W, H)
            self.glClearColor(0, 0, 0, 0)
            self.glClear(0x00004000)
            self.glDrawArrays(0x0004, 0, 3)
            self.glFinish()
            out = (C.c_ubyte * (W * H * 4))()
            self.glReadPixels(0, 0, W, H, 0x1908, 0x1401, out)
            return bytes(out)
        finally:
            self.glDeleteTextures(2, textures)

    def close(self):
        for program in self.programs.values(): self.glDeleteProgram(program)
        self.egl.eglMakeCurrent(self.display, None, None, None)
        self.egl.eglDestroySurface(self.display, self.surface)
        self.egl.eglDestroyContext(self.display, self.context)
        self.egl.eglTerminate(self.display)


def pixel(image, x=40, y=35):
    p = (y * W + x) * 4
    return tuple(image[p:p + 4])


class ShaderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.gpu = GPU()

    @classmethod
    def tearDownClass(cls): cls.gpu.close()

    def test_bright_background_black_at_all_animation_opacities(self):
        for flipped in (False, True):
            for opacity in (0.02, 0.12, 0.38, 0.5, 0.88, 1):
                with self.subTest(flipped=flipped, opacity=opacity):
                    p = pixel(self.gpu.render(lambda x, y: (255, 255, 255, 255), flipped=flipped, opacity=opacity))
                    self.assertEqual(p[:3], (0, 0, 0))
                    self.assertAlmostEqual(p[3], round(opacity * 255), delta=1)

    def test_dark_background_white_at_all_animation_opacities(self):
        for flipped in (False, True):
            for opacity in (0.02, 0.12, 0.38, 0.5, 0.88, 1):
                p = pixel(self.gpu.render(lambda x, y: (8, 8, 8, 255), flipped=flipped, opacity=opacity))
                self.assertEqual(p[0], p[3])
                self.assertEqual(p[1], p[3])
                self.assertEqual(p[2], p[3])
                self.assertAlmostEqual(p[3], round(opacity * 255), delta=1)

    def test_gles_uses_the_same_runtime_snapshot_coordinates(self):
        background = lambda x, y: (255, 255, 255, 255) if y < 25 else (0, 0, 0, 255)
        for sample in ((50, 10), (50, 80)):
            normal = self.gpu.render(background, sample=sample)
            flipped = self.gpu.render(background, sample=sample, flipped=True)
            self.assertEqual(normal, flipped)
        self.assertEqual(pixel(self.gpu.render(background))[:3], (0, 0, 0))

    def test_independent_groups_on_one_split_background(self):
        background = lambda x, y: (255, 255, 255, 255) if x < 48 else (0, 0, 0, 255)
        for flipped in (False, True):
            self.assertEqual(pixel(self.gpu.render(background, flipped=flipped, sample=(12, 10)))[:3], (0, 0, 0))
            self.assertEqual(pixel(self.gpu.render(background, flipped=flipped, sample=(80, 10)))[:3], (255, 255, 255))

    def test_two_glyphs_in_group_use_same_sample(self):
        background = lambda x, y: (255, 255, 255, 255) if y < 25 else (0, 0, 0, 255)
        for origin in ((24, 24), (24, 60)):
            for flipped in (False, True):
                out = self.gpu.render(background, origin=origin, flipped=flipped)
                self.assertEqual(pixel(out, 40, origin[1] + 8)[:3], (0, 0, 0))

    def test_extra_sample_coverage_does_not_paint_surface(self):
        out = self.gpu.render(lambda x, y: (255, 255, 255, 255))
        for x, y in ((1, 1), (48, 10), (23, 35), (56, 35), (40, 48), (90, 90)):
            self.assertEqual(pixel(out, x, y), (0, 0, 0, 0))

    def test_zero_opacity_has_no_output(self):
        out = self.gpu.render(lambda x, y: (255, 255, 255, 255), opacity=0)
        self.assertFalse(any(out))

    def test_blur_has_transparent_halo_without_smearing_mask_edges(self):
        background = lambda x, y: (255, 255, 255, 255)
        for flipped in (False, True):
            sharp = self.gpu.render(background, flipped=flipped)
            soft = self.gpu.render(background, flipped=flipped, sigma=1.6)
            self.assertEqual(pixel(sharp, 23, 35)[3], 0)
            self.assertGreater(pixel(soft, 23, 35)[3], 0)
            self.assertLess(pixel(soft, 24, 35)[3], 255)
            self.assertEqual(pixel(soft, 18, 35)[3], 0)
            self.assertEqual(pixel(soft, 48, 10), (0, 0, 0, 0))
            self.assertEqual(pixel(soft, 40, 35), (0, 0, 0, 255))

    def test_zero_mask_has_no_output(self):
        out = self.gpu.render(lambda x, y: (0, 0, 0, 255), mask_alpha=0)
        self.assertFalse(any(out))

    def test_partial_mask_and_opacity_are_premultiplied(self):
        out = self.gpu.render(lambda x, y: (0, 0, 0, 255), opacity=0.5, mask_alpha=128)
        self.assertEqual(pixel(out), (64, 64, 64, 64))

    def test_inverse_mask_handles_horizontal_reflection(self):
        background = lambda x, y: (255, 255, 255, 255)
        a = self.gpu.render(background)
        b = self.gpu.render(background, origin=(56, 24), x_axis=(-32, 0))
        self.assertEqual(a, b)

    def test_inverse_mask_handles_rotation_and_scale(self):
        background = lambda x, y: (255, 255, 255, 255)
        for flipped in (False, True):
            out = self.gpu.render(background, origin=(56, 24), x_axis=(0, 32), y_axis=(-24, 0), flipped=flipped)
            self.assertEqual(pixel(out, 40, 40), (0, 0, 0, 255))
            self.assertEqual(pixel(out, 28, 40), (0, 0, 0, 0))
            small = self.gpu.render(background, origin=(36, 30), x_axis=(16, 0), y_axis=(0, 12), flipped=flipped)
            self.assertEqual(pixel(small, 40, 35), (0, 0, 0, 255))
            self.assertEqual(pixel(small, 34, 35), (0, 0, 0, 0))

    def test_partial_backdrop_alpha_is_unpremultiplied(self):
        out = self.gpu.render(lambda x, y: (64, 64, 64, 64))
        self.assertEqual(pixel(out), (0, 0, 0, 255))

    def test_sampling_clamps_at_screen_edges(self):
        for sample in ((0, 0), (95, 95), (-2, -2), (99, 99)):
            out = self.gpu.render(lambda x, y: (255, 255, 255, 255), sample=sample)
            self.assertEqual(pixel(out), (0, 0, 0, 255))

    def test_threshold_response_is_monotonic_not_an_opacity_reset(self):
        colors = []
        for gray in range(90, 160, 2):
            out = self.gpu.render(lambda x, y: (gray, gray, gray, 255), opacity=0.88)
            colors.append(pixel(out)[0])
        self.assertEqual(colors, sorted(colors, reverse=True))
        self.assertEqual(colors[0], round(255 * 0.88))
        self.assertEqual(colors[-1], 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
