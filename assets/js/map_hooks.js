export const AtlasMap = {
  mounted() {
    const canvas = this.el.querySelector('[data-map-canvas]')
    this.map = window.L.map(canvas, {scrollWheelZoom: false}).setView([20, 0], 2)
    window.L.tileLayer(this.el.dataset.tileUrl, {
      maxZoom: 19,
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
    }).addTo(this.map)
    this.markers = window.L.featureGroup().addTo(this.map)
    this.updatePoints()
    this.resizeObserver = new ResizeObserver(() => this.map.invalidateSize())
    this.resizeObserver.observe(canvas)
  },
  updated() { this.updatePoints() },
  updatePoints() {
    const data = this.el.querySelector('[data-map-points]').textContent
    if (this.lastData === data) return
    this.lastData = data
    const points = JSON.parse(data)
    this.markers.clearLayers()
    points.forEach((point, index) => {
      const popup = document.createElement('div')
      popup.className = 'atlas-popup'
      const title = document.createElement('h3')
      title.textContent = point.title
      popup.appendChild(title)
      for (const value of [point.group_name, point.description, point.address,
        point.starts_at && new Date(point.starts_at).toLocaleString()]) {
        if (!value) continue
        const line = document.createElement('p')
        line.textContent = value
        popup.appendChild(line)
      }
      if (point.source_url) {
        const source = new URL(point.source_url)
        if (['http:', 'https:'].includes(source.protocol)) {
          const link = document.createElement('a')
          link.href = source.href
          link.target = '_blank'
          link.rel = 'noopener noreferrer'
          link.textContent = 'View on Campfire'
          popup.appendChild(link)
        }
      }
      window.L.marker([point.latitude, point.longitude], {
        title: point.title,
        icon: window.L.divIcon({className: '', iconSize: [28, 28], iconAnchor: [14, 28],
          html: `<div class="atlas-pin"><span>${index + 1}</span></div>`}),
      }).bindPopup(popup).addTo(this.markers)
    })
    if (points.length) this.map.fitBounds(this.markers.getBounds(), {padding: [45, 45], maxZoom: 14})
  },
  destroyed() { this.resizeObserver.disconnect(); this.map.remove() },
}

export const CopyLink = {
  mounted() {
    this.el.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(this.el.dataset.url)
        this.el.textContent = 'Link copied'
        setTimeout(() => { if (this.el.isConnected) this.el.textContent = 'Copy share link' }, 2000)
      } catch {
        const field = document.querySelector(this.el.dataset.target)
        if (field) { field.focus(); field.select() }
      }
    })
  },
}
