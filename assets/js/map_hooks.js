import {formatMeetupTime} from "./local_time.js"

function meetupImage(value, alt, className) {
  if (!value) return null
  try {
    if (!/^\/media\/meetups\/[0-9a-f]{64}(\?v=[12])?$/.test(value)) return null
    const image = document.createElement('img')
    image.src = value
    image.alt = alt
    image.loading = 'lazy'
    image.referrerPolicy = 'no-referrer'
    image.className = className
    image.addEventListener('error', () => { image.hidden = true })
    return image
  } catch {
    return null
  }
}

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
    const resizePopup = () => {
      if (!this.openPopup?.isOpen()) return
      this.openPopup.options.maxHeight = Math.max(80, Math.min(420, this.map.getSize().y - 80))
      this.openPopup.options.minWidth = Math.max(50, Math.min(250, this.map.getSize().x - 70))
      this.openPopup.update()
    }
    this.map.on('popupopen', ({popup}) => { this.openPopup = popup; resizePopup() })
    this.resizeObserver = new ResizeObserver(() => {
      this.map.invalidateSize()
      resizePopup()
    })
    this.resizeObserver.observe(canvas)
  },
  updated() { this.updatePoints() },
  updatePoints() {
    const data = this.el.querySelector('[data-map-points]').textContent
    if (this.lastData === data) return
    this.lastData = data
    const points = JSON.parse(data)
    this.markers.clearLayers()
    const locations = new Map()
    points.forEach(point => {
      const key = JSON.stringify([point.latitude, point.longitude])
      if (!locations.has(key)) locations.set(key, [])
      locations.get(key).push(point)
    })
    Array.from(locations.values()).forEach((meetups, index) => {
      const point = meetups[0]
      const popup = document.createElement('div')
      popup.className = 'atlas-popup'
      meetups.forEach(meetup => {
        const section = document.createElement('section')
        section.className = 'atlas-popup-meetup'
        const cover = meetupImage(meetup.cover_photo_url, meetup.title, 'atlas-meetup-image')
        if (cover) section.appendChild(cover)
        const title = document.createElement('h3')
        title.textContent = meetup.title
        section.appendChild(title)
        if (meetup.host_name || meetup.host_avatar_url) {
          const host = document.createElement('div')
          host.className = 'atlas-meetup-host'
          const avatar = meetupImage(meetup.host_avatar_url, '', '')
          if (avatar) host.appendChild(avatar)
          const name = document.createElement('span')
          name.textContent = `Hosted by ${meetup.host_name || 'Campfire host'}`
          host.appendChild(name)
          section.appendChild(host)
        }
        for (const value of [meetup.group_name, meetup.description, meetup.address,
          formatMeetupTime(meetup.starts_at, meetup.ends_at)]) {
          if (!value) continue
          const line = document.createElement('p')
          line.textContent = value
          section.appendChild(line)
        }
        const campfireUrl = meetup.campfire_url || meetup.source_url
        if (campfireUrl) {
          try {
            const source = new URL(campfireUrl)
            if (['http:', 'https:'].includes(source.protocol)) {
              const link = document.createElement('a')
              link.href = source.href
              link.target = '_blank'
              link.rel = 'noopener noreferrer'
              link.textContent = 'View on Campfire'
              section.appendChild(link)
            }
          } catch { /* Keep the remaining meetup details if its source link is invalid. */ }
        }
        popup.appendChild(section)
      })
      const count = meetups.length > 1 ? `<small class="atlas-pin-count">${meetups.length}</small>` : ''
      window.L.marker([point.latitude, point.longitude], {
        title: meetups.length > 1 ? `${point.title} · ${meetups.length} meetups` : point.title,
        zIndexOffset: (locations.size - index) * 100,
        icon: window.L.divIcon({className: '', iconSize: [28, 28], iconAnchor: [14, 28],
          html: `<div class="atlas-pin"><span>${index + 1}</span>${count}</div>`}),
      }).bindPopup(popup, {
        maxWidth: 340,
        minWidth: Math.max(50, Math.min(250, this.map.getSize().x - 70)),
        maxHeight: Math.max(80, Math.min(420, this.map.getSize().y - 80)),
      }).addTo(this.markers)
    })
    if (points.length) this.map.fitBounds(this.markers.getBounds(), {padding: [45, 45], maxZoom: 14})
  },
  destroyed() { this.resizeObserver.disconnect(); this.map.remove() },
}

export const CopyLink = {
  mounted() {
    const label = this.el.textContent.trim()
    this.el.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(this.el.dataset.url)
      } catch {
        const field = this.el.dataset.target && document.querySelector(this.el.dataset.target)
        if (field) { field.focus(); field.select(); return }

        const temporary = document.createElement('textarea')
        temporary.value = this.el.dataset.url
        temporary.style.cssText = 'position:fixed;left:-9999px'
        document.body.appendChild(temporary)
        temporary.select()
        try {
          if (!document.execCommand('copy')) return
        } finally {
          temporary.remove()
        }
      }
      this.el.textContent = 'Link copied'
      setTimeout(() => { if (this.el.isConnected) this.el.textContent = label }, 2000)
    })
  },
}

export const MeetupDate = {
  mounted() {
    const date = this.el.querySelector('input[type="date"]')
    const offset = this.el.querySelector('#meetup-date-offset')
    const sync = () => {
      const day = date.value ? new Date(`${date.value}T00:00:00`) : new Date()
      offset.value = String(-day.getTimezoneOffset())
    }
    date.addEventListener('change', sync)
    this.el.addEventListener('submit', sync, true)
    sync()
  },
}

export const ConfirmDialog = {
  mounted() {
    this.targetId = this.el.dataset.targetId
    this.el.addEventListener('atlas:open', () => { if (!this.el.open) this.el.showModal() })
    this.el.addEventListener('click', event => { if (event.target === this.el) this.el.close() })
  },
  updated() {
    if (this.targetId !== this.el.dataset.targetId && this.el.open) this.el.close()
    this.targetId = this.el.dataset.targetId
  },
}
