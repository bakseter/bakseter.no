export default {
  layout: 'layouts/post.njk',
  tags: 'posts',
  permalink: (data) => `/blog/${data.page.fileSlug}/`,
};
