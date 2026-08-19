import { defineConfig, type Plugin } from 'vite';
import { cpSync, existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';

// يُبنى إلى dist/ ويُنشر على GitHub Pages تحت مسار المستودع.
// التوجيه بالـhash عمداً: Pages لا يملك إعادة كتابة للمسارات، والتوجيه
// التاريخي يحتاج 404 يعيد الصفحة نفسها — حيلة تعمل وتُربك عند التشخيص.
// والـhash يجعل الرابط العميق يعمل بلا أي إعداد على الخادم.

/**
 * الملفّات القديمة تُحمَّل سكربتات كلاسيكية لا وحدات، فلا يلمسها المُجمِّع.
 * تُنسخ كما هي إلى المخرَج.
 */
function copyLegacyAssets(): Plugin {
  return {
    name: 'babil-copy-legacy-assets',
    apply: 'build',
    closeBundle() {
      for (const dir of ['assets/js', 'assets/vendor', 'assets/css', 'assets/data']) {
        if (existsSync(dir)) cpSync(dir, resolve('dist', dir), { recursive: true });
      }
    },
  };
}

/**
 * الحارس الذي يجعل خطوة البناء آمنة.
 *
 * إدخال البناء أدخل عطلاً جديداً: قبله كان الملف المعطوب يُبقي نسخته السابقة
 * تخدم، وبعده قد يُنشَر مخرَج ينقصه ملف فيسقط التطبيق عند التحميل. وأوّل بناء
 * هنا أنتج dist بلا السكربتات القديمة ولا xlsx إطلاقاً.
 *
 * فيُفحص المخرَج: كل ما يشير إليه index.html يجب أن يوجد فيه فعلاً، وإلا فشل
 * البناء. الفشل عند البناء أرخص من اكتشافه في الإنتاج بكثير.
 */
function verifyBundle(): Plugin {
  return {
    name: 'babil-verify-bundle',
    apply: 'build',
    closeBundle() {
      const html = readFileSync(resolve('dist', 'index.html'), 'utf8');
      const refs = [...html.matchAll(/(?:src|href)="(\.\/[^"]+)"/g)].map((m) => m[1] as string);
      const missing = refs.filter((r) => !existsSync(resolve('dist', r.replace(/^\.\//, ''))));
      if (missing.length) {
        throw new Error(
          'BUILD REJECTED — dist references files it does not contain:\n  '
          + missing.join('\n  ')
          + '\nA deploy from this output would fail to load.',
        );
      }
      console.log(`  bundle verified: ${refs.length} referenced assets all present`);
    },
  };
}

export default defineConfig({
  base: './',
  plugins: [copyLegacyAssets(), verifyBundle()],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    target: 'es2022',
    sourcemap: true,
  },
  server: { port: 4180 },
});
