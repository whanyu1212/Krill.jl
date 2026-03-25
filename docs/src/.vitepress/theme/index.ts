// .vitepress/theme/index.ts
import { h } from 'vue'
import type { Theme } from 'vitepress'
import DefaultTheme from 'vitepress/theme'
import './style.css'
import './docstrings.css'
import { initDiagramViewers } from './diagramViewer'

export default {
  extends: DefaultTheme,
  Layout() {
    return h(DefaultTheme.Layout, null, {})
  },
  enhanceApp({ router }) {
    if (typeof window === 'undefined') return

    // The Mermaid Vue component renders asynchronously via <Suspense>.
    // We observe the entire document for new SVGs appearing inside .mermaid elements.
    const observer = new MutationObserver(() => { initDiagramViewers() })
    observer.observe(document.documentElement, { childList: true, subtree: true })

    // Also fire explicitly after navigation in case the observer misses it
    router.onAfterRouteChange = () => {
      setTimeout(initDiagramViewers, 200)
      setTimeout(initDiagramViewers, 1000)
    }

    // Initial page load
    window.addEventListener('load', () => {
      setTimeout(initDiagramViewers, 200)
      setTimeout(initDiagramViewers, 1000)
    })
  },
} satisfies Theme
