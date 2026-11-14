// SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
// SPDX-License-Identifier: GPL-2.0-or-later
// Start virglrenderer on OpenGL ES contexts that this program makes with EGL through libepoxy,
// on ANGLE's Metal backend, as QEMU does: virglrenderer creates its contexts through the
// callbacks. Print the GL renderer epoxy sees and the virgl capability sets, then create a
// rendering context and a texture resource. Exit status: 0 when it worked, 2 when ANGLE's Metal
// backend could not initialise (no Metal device), 1 for anything else.
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <epoxy/egl.h>
#include <epoxy/gl.h>
#include <virglrenderer.h>

#ifndef EGL_PLATFORM_ANGLE_ANGLE
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif

static EGLDisplay dpy;
static EGLConfig config;
static EGLContext first;

static int fail(const char *what)
{
	fprintf(stderr, "FAIL: %s (EGL error 0x%04x)\n", what, eglGetError());
	return 1;
}

static virgl_renderer_gl_context create_gl_context(void *cookie, int scanout,
						   struct virgl_renderer_gl_ctx_param *param)
{
	(void)cookie;
	(void)scanout;
	const EGLint attribs[] = {
		EGL_CONTEXT_MAJOR_VERSION, param->major_ver,
		EGL_CONTEXT_MINOR_VERSION, param->minor_ver,
		EGL_NONE,
	};
	EGLContext ctx = eglCreateContext(dpy, config, param->shared ? first : EGL_NO_CONTEXT,
					  attribs);
	printf("create_gl_context ES %d.%d%s: %s\n", param->major_ver, param->minor_ver,
	       param->shared ? " shared" : "", ctx == EGL_NO_CONTEXT ? "refused" : "ok");
	if (ctx != EGL_NO_CONTEXT && first == EGL_NO_CONTEXT)
		first = ctx;
	return ctx == EGL_NO_CONTEXT ? NULL : ctx;
}

static void destroy_gl_context(void *cookie, virgl_renderer_gl_context ctx)
{
	(void)cookie;
	eglDestroyContext(dpy, ctx);
}

static int make_current(void *cookie, int scanout, virgl_renderer_gl_context ctx)
{
	(void)cookie;
	(void)scanout;
	return eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx) ? 0 : -1;
}

static void write_fence(void *cookie, uint32_t fence)
{
	(void)cookie;
	(void)fence;
}

int main(void)
{
	printf("epoxy_has_egl: %d\n", epoxy_has_egl());
	// eglGetPlatformDisplayEXT, as QEMU calls it: before there is a display, libepoxy can only
	// see client extensions, not that EGL is 1.5
	const EGLint display_attribs[] = {
		EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
		EGL_NONE,
	};
	dpy = eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, (void *)EGL_DEFAULT_DISPLAY,
				       display_attribs);
	if (dpy == EGL_NO_DISPLAY)
		return fail("eglGetPlatformDisplayEXT");
	EGLint major, minor;
	if (!eglInitialize(dpy, &major, &minor)) {
		fprintf(stderr, "eglInitialize failed (EGL error 0x%04x): no Metal device?\n",
			eglGetError());
		return 2;
	}
	printf("EGL %d.%d %s, epoxy_egl_version %d\n", major, minor,
	       eglQueryString(dpy, EGL_VERSION), epoxy_egl_version(dpy));
	if (!epoxy_has_egl_extension(dpy, "EGL_KHR_surfaceless_context"))
		return fail("no EGL_KHR_surfaceless_context");
	const EGLint config_attribs[] = {
		EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
		EGL_NONE,
	};
	EGLint n;
	if (!eglChooseConfig(dpy, config_attribs, &config, 1, &n) || n < 1)
		return fail("eglChooseConfig");
	if (!eglBindAPI(EGL_OPENGL_ES_API))
		return fail("eglBindAPI");

	static struct virgl_renderer_callbacks cb = {
		.version = 1,
		.write_fence = write_fence,
		.create_gl_context = create_gl_context,
		.destroy_gl_context = destroy_gl_context,
		.make_current = make_current,
	};
	// virglrenderer wants a cookie, which it passes back to the callbacks
	int r = virgl_renderer_init(&dpy, VIRGL_RENDERER_USE_GLES, &cb);
	if (r) {
		fprintf(stderr, "FAIL: virgl_renderer_init: %d\n", r);
		return 1;
	}
	if (first == EGL_NO_CONTEXT || !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, first))
		return fail("no virglrenderer context to look at");
	printf("GL_RENDERER: %s\nGL_VERSION: %s\nepoxy_gl_version %d, desktop GL %d\n",
	       glGetString(GL_RENDERER), glGetString(GL_VERSION), epoxy_gl_version(),
	       epoxy_is_desktop_gl());

	// virtio-gpu capability sets 1 (virgl) and 2 (virgl2)
	uint32_t sets[] = { 1, 2 };
	for (unsigned i = 0; i < sizeof(sets) / sizeof(sets[0]); i++) {
		uint32_t max_ver = 0, max_size = 0;
		virgl_renderer_get_cap_set(sets[i], &max_ver, &max_size);
		printf("capset %u: version %u, %u bytes\n", sets[i], max_ver, max_size);
		if (!max_size) {
			fprintf(stderr, "FAIL: capset %u is empty\n", sets[i]);
			return 1;
		}
	}

	const char name[] = "virgl-check";
	r = virgl_renderer_context_create(1, sizeof(name) - 1, name);
	if (r) {
		fprintf(stderr, "FAIL: virgl_renderer_context_create: %d\n", r);
		return 1;
	}
	// a 64x64 2D texture, B8G8R8A8_UNORM (1), bound as a render target (2) and sampler view (8)
	struct virgl_renderer_resource_create_args args = {
		.handle = 1, .target = 2, .format = 1, .bind = 2 | 8,
		.width = 64, .height = 64, .depth = 1, .array_size = 1,
	};
	r = virgl_renderer_resource_create(&args, NULL, 0);
	if (r) {
		fprintf(stderr, "FAIL: virgl_renderer_resource_create: %d\n", r);
		return 1;
	}
	virgl_renderer_ctx_attach_resource(1, 1);
	virgl_renderer_ctx_detach_resource(1, 1);
	virgl_renderer_resource_unref(1);
	virgl_renderer_context_destroy(1);
	virgl_renderer_cleanup(&dpy);
	printf("virglrenderer: initialised on ES, created a context and a texture\n");
	return 0;
}
