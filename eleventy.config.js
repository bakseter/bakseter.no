import { feedPlugin } from '@11ty/eleventy-plugin-rss';

export default function (eleventyConfig) {
  // Everything in src/static is copied to the site root (favicon.ico, CNAME, cv.pdf, ...)
  eleventyConfig.addPassthroughCopy({ 'src/static': '/' });

  // Tailwind writes straight to _site/css; reload the browser when it does
  eleventyConfig.setServerOptions({ watch: ['_site/css/**/*.css'] });

  eleventyConfig.addShortcode('year', () => String(new Date().getFullYear()));

  // Filters
  eleventyConfig.addFilter('readableDate', (date) =>
    date.toLocaleDateString('en-GB', {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
      timeZone: 'UTC',
    }),
  );
  eleventyConfig.addFilter('htmlDateString', (date) =>
    date.toISOString().slice(0, 10),
  );
  // Newest first, optionally limited: collections.posts | latest(3)
  eleventyConfig.addFilter('latest', (posts, n) => {
    const sorted = [...posts].reverse();
    return n ? sorted.slice(0, n) : sorted;
  });

  // Atom feed at /feed.xml
  eleventyConfig.addPlugin(feedPlugin, {
    type: 'atom',
    outputPath: '/feed.xml',
    collection: { name: 'posts', limit: 20 },
    metadata: {
      language: 'en',
      title: 'bakseter.no',
      subtitle: 'k8s, cloud native, homelabbing',
      base: 'https://bakseter.no/',
      author: { name: 'Andreas Salhus Bakseter' },
    },
  });
}

export const config = {
  dir: { input: 'src', output: '_site' },
  markdownTemplateEngine: false,
  htmlTemplateEngine: 'njk',
};
