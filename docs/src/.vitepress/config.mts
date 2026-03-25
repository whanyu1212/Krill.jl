import { defineConfig } from 'vitepress'
import { withMermaid } from 'vitepress-plugin-mermaid'

// DocumenterVitepress.jl replaces these at build time.
// For local preview (`npm run docs:dev`), the fallback values below are used.
const defined = (s: string) => !s.startsWith('REPLACE_ME')

const base = defined('REPLACE_ME_DOCUMENTER_VITEPRESS') ? 'REPLACE_ME_DOCUMENTER_VITEPRESS' : '/'
const title = defined('REPLACE_ME_DOCUMENTER_VITEPRESS') ? 'REPLACE_ME_DOCUMENTER_VITEPRESS' : 'Krill.jl'
const outDir = defined('REPLACE_ME_DOCUMENTER_VITEPRESS') ? 'REPLACE_ME_DOCUMENTER_VITEPRESS' : '../build'
const logo = defined('REPLACE_ME_DOCUMENTER_VITEPRESS') ? 'REPLACE_ME_DOCUMENTER_VITEPRESS' : ''
const favicon = defined('REPLACE_ME_DOCUMENTER_VITEPRESS_FAVICON') ? 'REPLACE_ME_DOCUMENTER_VITEPRESS_FAVICON' : '/favicon.ico'
const editLink = defined('REPLACE_ME_DOCUMENTER_VITEPRESS') ? 'REPLACE_ME_DOCUMENTER_VITEPRESS' : undefined
const socialLink = defined('REPLACE_ME_DOCUMENTER_VITEPRESS') ? 'REPLACE_ME_DOCUMENTER_VITEPRESS' : 'https://github.com/hanyuwu/Krill.jl'

export default withMermaid(defineConfig({
  mermaid: {
    theme: 'base',
    themeVariables: {
      fontSize: '14px',
    },
  },
  mermaidPlugin: {},
  base,
  title,
  description: 'Personal AI assistant runtime in Julia — inspired by OpenClaw and nanobot',
  lastUpdated: true,
  cleanUrls: true,
  outDir,
  head: [['link', { rel: 'icon', href: favicon }]],
  ignoreDeadLinks: true,

  markdown: {
    theme: {
      light: 'github-light',
      dark: 'github-dark',
    },
  },

  themeConfig: {
    outline: 'deep',
    ...(logo ? { logo } : {}),
    search: {
      provider: 'local',
      options: {
        detailedView: true,
      },
    },
    nav: 'REPLACE_ME_DOCUMENTER_VITEPRESS',
    sidebar: 'REPLACE_ME_DOCUMENTER_VITEPRESS',
    ...(editLink ? { editLink } : {}),
    socialLinks: [{ icon: 'github', link: socialLink }],
    footer: {
      message:
        'Made with <a href="https://documenter.juliadocs.org/stable/" target="_blank"><strong>Documenter.jl</strong></a> & <a href="https://vitepress.dev" target="_blank"><strong>VitePress</strong></a><br>',
      copyright: `© Copyright ${new Date().getUTCFullYear()} hanyuwu and contributors.`,
    },
  },
}))
