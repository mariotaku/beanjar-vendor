// SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
// SPDX-License-Identifier: GPL-2.0-or-later
// Create an EGL display with ANGLE's Metal backend, an OpenGL ES 3 context on a pbuffer, clear it
// and read a pixel back, and print GL_RENDERER and GL_VERSION. Exit status: 0 when it worked,
// 2 when the Metal backend could not initialise (no Metal device), 1 for anything else.
#include <stdio.h>
#include <string.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <GLES3/gl3.h>

static int fail(const char *what)
{
	fprintf(stderr, "FAIL: %s (EGL error 0x%04x)\n", what, eglGetError());
	return 1;
}

int main(void)
{
	const char *client = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
	if (!client || !strstr(client, "EGL_ANGLE_platform_angle_metal"))
		return fail("no EGL_ANGLE_platform_angle_metal");
	printf("EGL client extensions: %s\n", client);

	const EGLAttrib display_attribs[] = {
		EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
		EGL_NONE,
	};
	EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE,
					       (void *)EGL_DEFAULT_DISPLAY, display_attribs);
	if (dpy == EGL_NO_DISPLAY)
		return fail("eglGetPlatformDisplay");
	EGLint major, minor;
	if (!eglInitialize(dpy, &major, &minor)) {
		fprintf(stderr, "eglInitialize failed (EGL error 0x%04x): no Metal device?\n",
			eglGetError());
		return 2;
	}
	printf("EGL %d.%d, vendor %s, version %s\n", major, minor,
	       eglQueryString(dpy, EGL_VENDOR), eglQueryString(dpy, EGL_VERSION));

	const EGLint config_attribs[] = {
		EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
		EGL_NONE,
	};
	EGLConfig config;
	EGLint n;
	if (!eglChooseConfig(dpy, config_attribs, &config, 1, &n) || n < 1)
		return fail("eglChooseConfig");
	const EGLint pbuffer_attribs[] = { EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE };
	EGLSurface surface = eglCreatePbufferSurface(dpy, config, pbuffer_attribs);
	if (surface == EGL_NO_SURFACE)
		return fail("eglCreatePbufferSurface");
	const EGLint context_attribs[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE };
	EGLContext ctx = eglCreateContext(dpy, config, EGL_NO_CONTEXT, context_attribs);
	if (ctx == EGL_NO_CONTEXT)
		return fail("eglCreateContext");
	if (!eglMakeCurrent(dpy, surface, surface, ctx))
		return fail("eglMakeCurrent");

	printf("GL_VENDOR: %s\nGL_RENDERER: %s\nGL_VERSION: %s\nGL_SHADING_LANGUAGE_VERSION: %s\n",
	       glGetString(GL_VENDOR), glGetString(GL_RENDERER), glGetString(GL_VERSION),
	       glGetString(GL_SHADING_LANGUAGE_VERSION));
	glClearColor(1.0f, 0.0f, 1.0f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	unsigned char px[4] = { 0 };
	glReadPixels(8, 8, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
	if (glGetError() != GL_NO_ERROR || px[0] != 255 || px[1] != 0 || px[2] != 255)
		return fail("cleared pixel did not read back as magenta");
	printf("cleared and read back a pixel: %u %u %u %u\n", px[0], px[1], px[2], px[3]);

	eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglDestroyContext(dpy, ctx);
	eglDestroySurface(dpy, surface);
	eglTerminate(dpy);
	return 0;
}
