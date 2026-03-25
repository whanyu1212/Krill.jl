// diagramViewer.ts — adds expand/zoom/pan controls to Mermaid-rendered diagrams
// Does NOT reparent the .mermaid element — just injects sibling elements around it

interface State {
  scale: number
  tx: number
  ty: number
  panning: boolean
  lastX: number
  lastY: number
  lastDist: number
  lastTx: number
  lastTy: number
}

function makeBtn(html: string, extra = ''): HTMLButtonElement {
  const b = document.createElement('button')
  b.className = 'dv-btn' + (extra ? ' ' + extra : '')
  b.innerHTML = html
  return b
}

function attachViewer(mermaidEl: HTMLElement) {
  if (mermaidEl.dataset.dvInit) return
  mermaidEl.dataset.dvInit = '1'

  // Add styling class to the mermaid element's parent for the card look
  mermaidEl.classList.add('dv-preview')

  // Insert toolbar BEFORE the mermaid element (as a sibling)
  const toolbar = document.createElement('div')
  toolbar.className = 'dv-toolbar-inline'
  const expandBtn = makeBtn(
    `<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="15 3 21 3 21 9"/><polyline points="9 21 3 21 3 15"/><line x1="21" y1="3" x2="14" y2="10"/><line x1="3" y1="21" x2="10" y2="14"/></svg> Expand`
  )
  toolbar.appendChild(expandBtn)
  mermaidEl.parentNode!.insertBefore(toolbar, mermaidEl)

  // ── Modal ─────────────────────────────────────────────────────────────────
  const overlay = document.createElement('div')
  overlay.className = 'dv-overlay'
  overlay.tabIndex = -1
  overlay.style.display = 'none'

  const modal = document.createElement('div')
  modal.className = 'dv-modal'

  const modalToolbar = document.createElement('div')
  modalToolbar.className = 'dv-modal-toolbar'

  const zoomControls = document.createElement('div')
  zoomControls.className = 'dv-zoom-controls'

  const zoomOutBtn = makeBtn(`<svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="5" y1="12" x2="19" y2="12"/></svg>`)
  const label = document.createElement('span')
  label.className = 'dv-zoom-label'
  label.textContent = '100%'
  const zoomInBtn = makeBtn(`<svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>`)
  const resetBtn = makeBtn('Reset')
  const closeBtn = makeBtn(
    `<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg> Close`,
    'dv-close-btn'
  )

  zoomControls.append(zoomOutBtn, label, zoomInBtn, resetBtn)
  modalToolbar.append(zoomControls, closeBtn)

  const canvas = document.createElement('div')
  canvas.className = 'dv-canvas'
  const content = document.createElement('div')
  content.className = 'dv-content'
  content.style.cursor = 'grab'
  canvas.appendChild(content)
  modal.append(modalToolbar, canvas)
  overlay.appendChild(modal)
  document.body.appendChild(overlay)

  // ── State ─────────────────────────────────────────────────────────────────
  const s: State = { scale: 1, tx: 0, ty: 0, panning: false, lastX: 0, lastY: 0, lastDist: 0, lastTx: 0, lastTy: 0 }

  function sync() {
    content.style.transform = `translate(${s.tx}px, ${s.ty}px) scale(${s.scale})`
    label.textContent = `${Math.round(s.scale * 100)}%`
  }

  function open() {
    const svg = mermaidEl.querySelector('svg')
    if (!svg) return

    s.scale = 1; s.tx = 0; s.ty = 0
    sync()

    const clone = svg.cloneNode(true) as SVGElement
    clone.removeAttribute('style')
    clone.removeAttribute('width')
    clone.removeAttribute('height')
    clone.style.display = 'block'

    const vb = clone.getAttribute('viewBox')
    if (vb) {
      const parts = vb.trim().split(/[\s,]+/).map(Number)
      if (parts.length >= 4 && parts[2] && parts[3]) {
        clone.style.width = `${parts[2]}px`
        clone.style.height = `${parts[3]}px`
      }
    }

    content.innerHTML = ''
    content.appendChild(clone)
    overlay.style.display = 'flex'
    overlay.focus()

    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        const cw = canvas.clientWidth - 64
        const ch = canvas.clientHeight - 64
        const sw = clone.clientWidth || parseFloat(clone.style.width) || 800
        const sh = clone.clientHeight || parseFloat(clone.style.height) || 600
        if (sw && sh) {
          s.scale = Math.min(cw / sw, ch / sh, 1.5)
          sync()
        }
      })
    })
  }

  function close() {
    overlay.style.display = 'none'
    content.innerHTML = ''
  }

  expandBtn.addEventListener('click', open)
  closeBtn.addEventListener('click', close)
  overlay.addEventListener('click', (e) => { if (e.target === overlay) close() })
  overlay.addEventListener('keydown', (e) => { if (e.key === 'Escape') close() })

  zoomInBtn.addEventListener('click', () => { s.scale = Math.min(s.scale * 1.25, 8); sync() })
  zoomOutBtn.addEventListener('click', () => { s.scale = Math.max(s.scale / 1.25, 0.1); sync() })
  resetBtn.addEventListener('click', () => { s.scale = 1; s.tx = 0; s.ty = 0; sync() })

  canvas.addEventListener('mousedown', (e) => {
    s.panning = true; s.lastX = e.clientX; s.lastY = e.clientY
    content.style.cursor = 'grabbing'
  })
  canvas.addEventListener('mousemove', (e) => {
    if (!s.panning) return
    s.tx += e.clientX - s.lastX; s.ty += e.clientY - s.lastY
    s.lastX = e.clientX; s.lastY = e.clientY
    sync()
  })
  const endPan = () => { s.panning = false; content.style.cursor = 'grab' }
  canvas.addEventListener('mouseup', endPan)
  canvas.addEventListener('mouseleave', endPan)

  canvas.addEventListener('wheel', (e) => {
    e.preventDefault()
    s.scale = Math.min(Math.max(s.scale * (e.deltaY > 0 ? 0.9 : 1.1), 0.1), 8)
    sync()
  }, { passive: false })

  canvas.addEventListener('touchstart', (e) => {
    e.preventDefault()
    if (e.touches.length === 2) {
      s.lastDist = Math.hypot(e.touches[0].clientX - e.touches[1].clientX, e.touches[0].clientY - e.touches[1].clientY)
    } else {
      s.lastTx = e.touches[0].clientX; s.lastTy = e.touches[0].clientY
    }
  }, { passive: false })

  canvas.addEventListener('touchmove', (e) => {
    e.preventDefault()
    if (e.touches.length === 2) {
      const d = Math.hypot(e.touches[0].clientX - e.touches[1].clientX, e.touches[0].clientY - e.touches[1].clientY)
      s.scale = Math.min(Math.max(s.scale * (d / s.lastDist), 0.1), 8)
      s.lastDist = d
    } else {
      s.tx += e.touches[0].clientX - s.lastTx; s.ty += e.touches[0].clientY - s.lastTy
      s.lastTx = e.touches[0].clientX; s.lastTy = e.touches[0].clientY
    }
    sync()
  }, { passive: false })
}

export function initDiagramViewers() {
  document.querySelectorAll<HTMLElement>('.mermaid').forEach((el) => {
    if (el.dataset.dvInit) return
    if (el.querySelector('svg')) {
      attachViewer(el)
    }
  })
}
