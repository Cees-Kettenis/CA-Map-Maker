import test from 'node:test'
import assert from 'node:assert/strict'
import {AtlasMap, CopyLink, CommunitySearch} from '../../assets/js/map_hooks.js'

test('community search preserves selections and filtering across LiveView updates', () => {
  const search = {value: ''}
  const list = {scrollTop: 200}
  const results = {textContent: ''}
  const empty = {hidden: true}
  const options = [
    {dataset: {communityName: 'Butterworth Raid Crew'}, hidden: false, checked: true},
    {dataset: {communityName: 'Bayan Baru Trainers'}, hidden: false, checked: false},
  ]
  const listeners = {}
  const hook = {el: {
    querySelector(selector) {
      return {
        '[data-community-search]': search,
        '[data-community-list]': list,
        '[data-community-results]': results,
        '[data-community-empty]': empty,
      }[selector]
    },
    querySelectorAll() { return options },
    addEventListener(event, listener) { listeners[event] = listener },
    removeEventListener(event, listener) { assert.equal(listeners[event], listener); delete listeners[event] },
  }, ...CommunitySearch}

  hook.mounted()
  search.value = '  BUTTERWORTH  '
  listeners.input({target: {...search, matches() { return true }}})
  assert.deepEqual(options.map(option => option.hidden), [false, true])
  assert.deepEqual(options.map(option => option.checked), [true, false])
  assert.equal(results.textContent, '1 of 2 communities')
  assert.equal(list.scrollTop, 0)

  options.push({dataset: {communityName: 'Butterworth Weekend Trainers'}, hidden: false, checked: false})
  search.value = ''
  hook.updated()
  assert.equal(search.value, '  BUTTERWORTH  ')
  assert.equal(results.textContent, '2 of 3 communities')
  assert.deepEqual(options.map(option => option.checked), [true, false, false])

  listeners.input({target: {value: 'unknown group', matches() { return true }}})
  assert.equal(empty.hidden, false)
  assert.ok(options.every(option => option.hidden))
  listeners.input({target: {value: '', matches() { return true }}})
  assert.equal(empty.hidden, true)
  assert.ok(options.every(option => !option.hidden))
  hook.destroyed()
  assert.equal(listeners.input, undefined)
})

test('public link buttons copy without a visible URL field, including the clipboard fallback', async () => {
  const previousNavigator = Object.getOwnPropertyDescriptor(globalThis, 'navigator')
  const previousDocument = globalThis.document

  try {
    for (const [clipboardAvailable, withIcon, prepare] of [[true, false], [false, false], [true, true], [false, true], [true, true, true], [false, true, true]]) {
      const url = 'https://example.com/maps/shared-map'
      let copied
      let temporary
      const handlers = {}
      const labelElement = withIcon ? {textContent: 'Copy public link'} : null
      const el = {textContent: 'Copy public link', dataset: {url}, isConnected: false,
        querySelector() { return labelElement },
        addEventListener(event, handler) { handlers[event] = handler }}
      if (prepare) el.dataset = {prepareEvent: 'copy_public_link'}

      Object.defineProperty(globalThis, 'navigator', {configurable: true, value: {
        clipboard: {async writeText(value) {
          if (!clipboardAvailable) throw new Error('Clipboard unavailable')
          copied = value
        }},
      }})
      globalThis.document = {
        createElement() { return {style: {}, select() {}, remove() { temporary = null }} },
        body: {appendChild(field) { temporary = field }},
        execCommand(command) { assert.equal(command, 'copy'); copied = temporary.value; return true },
      }

      CopyLink.mounted.call({el, pushEvent(event, params, reply) {
        assert.equal(event, 'copy_public_link')
        assert.deepEqual(params, {})
        reply({url})
      }})
      await handlers.click()
      assert.equal(copied, url)
      assert.equal((labelElement || el).textContent, 'Link copied')
      if (withIcon) assert.equal(el.textContent, 'Copy public link')
      assert.ok(!temporary)
    }
  } finally {
    if (previousNavigator) Object.defineProperty(globalThis, 'navigator', previousNavigator)
    else delete globalThis.navigator
    globalThis.document = previousDocument
  }
})

function renderMarkers(points, mapHeight = 510, mapWidth = 1200, dataset = {}, hook = {}) {
  const markers = []
  const listeners = {}
  const map = {
    zoom: 2,
    setView(_center, zoom) { this.zoom = zoom; return this },
    on(event, listener) { listeners[event] = listener },
    fitBounds() { this.zoom = 14; this.fire('zoomend'); this.fire('moveend') },
    fire(event) {
      listeners[event]?.()
    },
    setZoom(zoom) { this.zoom = zoom; this.fire('zoomend'); this.fire('moveend') },
    getZoom() { return this.zoom },
    getSize() { return {x: mapWidth, y: mapHeight} },
  }
  const group = {addTo() { return this }, clearLayers() {}, getBounds() { return [] }}
  globalThis.document = {
    createElement(tag) {
      return {tag, children: [], listeners: {}, style: {}, appendChild(child) { this.children.push(child) },
        addEventListener(event, handler) {
          const previous = this.listeners[event]
          this.listeners[event] = (...args) => { previous?.(...args); handler(...args) }
        }}
    },
  }
  globalThis.ResizeObserver = class { observe() {} }
  globalThis.window = {L: {
    map() { return map },
    tileLayer() { return {addTo() {}} },
    featureGroup() { return group },
    divIcon(options) { return {...options, options} },
    marker(coordinates, options) {
      const marker = {coordinates, options, iconChanges: 0,
        setIcon(icon) { this.options.icon = icon; this.iconChanges++; return this },
        bindPopup(popup, config) { this.popup = popup; this.config = config; return this }, addTo() { return this }}
      markers.push(marker)
      return marker
    },
  }}
  Object.assign(hook, AtlasMap, {
    el: {dataset, querySelector() { return {textContent: JSON.stringify(points)} }},
  })
  hook.mounted()
  return markers
}

const meetup = (title, longitude, extra = {}) => ({title, latitude: 3.139, longitude, ...extra})

test('public popups link to Campfire without owner source metadata', () => {
  const campfireUrl = 'https://campfire.nianticlabs.com/discover/meetup/event-id'
  const [marker] = renderMarkers([meetup('Public meetup', 101.68, {campfire_url: campfireUrl})])
  const link = marker.popup.children[0].children.find(child => child.tag === 'a')
  assert.equal(link.href, campfireUrl)
  assert.equal(link.textContent, 'View on Campfire')
  assert.equal(link.target, '_blank')
  assert.equal(link.rel, 'noopener noreferrer')

  const [unsafe] = renderMarkers([meetup('Invalid link', 101.68, {campfire_url: 'javascript:alert(1)'})])
  assert.ok(!unsafe.popup.children[0].children.some(child => child.tag === 'a'))
})

test('meetups at the same coordinates share a marker with the next meetup first', () => {
  const markers = renderMarkers([meetup('Soonest', 101.68), meetup('Another location', 101.70), meetup('Later at the same place', 101.68)])
  assert.equal(markers.length, 2)
  assert.deepEqual(markers[0].popup.children.map(section => section.children[0].textContent), ['Soonest', 'Later at the same place'])
  assert.match(markers[0].options.title, /^Soonest/)
  assert.equal(markers[0].options.icon.html.children[0].className, 'atlas-pin-count')
  assert.equal(markers[0].options.icon.html.children[0].textContent, '2')
  assert.ok(markers[0].options.zIndexOffset > markers[1].options.zIndexOffset)
  assert.equal(markers[0].config.maxHeight, 420)
})

test('default markers are plain without sequence numbers and use the chosen colour', () => {
  const [marker] = renderMarkers([meetup('First', 101.68)])
  assert.equal(marker.options.icon.html.children.length, 0)
  assert.equal(marker.options.icon.html.style.backgroundColor, '#2563eb')
  const [custom] = renderMarkers([meetup('First', 101.68)], 510, 1200, {markerColor: '#be123c'})
  assert.equal(custom.options.icon.html.style.backgroundColor, '#be123c')
})

test('image marker styles reuse the correct local image, keep counts and fall back to plain pins', () => {
  const logo = `/media/meetups/${'e'.repeat(64)}?v=2`
  const photo = `/media/meetups/${'f'.repeat(64)}?v=1`
  for (const [style, expected] of [['community', logo], ['meetup', photo]]) {
    const markers = renderMarkers([
      meetup('Next', 101.68, {community_logo_url: logo, meetup_photo_url: photo}),
      meetup('Later', 101.68, {community_logo_url: photo, meetup_photo_url: logo}),
      meetup('Missing', 101.70),
    ], 380, 333, {markerStyle: style, markerColor: '#16a34a'})
    const pin = markers[0].options.icon.html
    assert.equal(pin.children[0].src, expected)
    assert.equal(pin.children[0].className, 'atlas-pin-image')
    assert.equal(pin.children[1].textContent, '2')
    pin.children[0].listeners.error()
    assert.equal(pin.children[0].hidden, true)
    assert.equal(pin.style.backgroundColor, '#16a34a')
    assert.equal(markers[1].options.icon.html.children.length, 0)
  }
})

test('marker images and colours reject untrusted values', () => {
  for (const value of ['https://cdn.example.com/logo.png', 'javascript:alert(1)', `/media/meetups/${'a'.repeat(64)}?v=2&extra=1`]) {
    for (const style of ['community', 'meetup']) {
      const [marker] = renderMarkers([meetup('Unsafe', 101.68, {community_logo_url: value, meetup_photo_url: value})], 510, 1200, {markerStyle: style, markerColor: 'red; color:green'})
      assert.equal(marker.options.icon.html.children.length, 0)
      assert.equal(marker.options.icon.html.style.backgroundColor, '#2563eb')
    }
  }
})

test('image markers show thumbnails at zoom 12 and larger images at zoom 14 without changing plain pins or popups', () => {
  const imageUrl = `/media/meetups/${'a'.repeat(64)}`
  for (const style of ['community', 'meetup', 'plain']) {
    const hook = {}
    const [marker, fallback] = renderMarkers([
      meetup('First', 101.68, {community_logo_url: imageUrl, meetup_photo_url: imageUrl}),
      meetup('Second', 101.68), meetup('No image', 101.70),
    ], 510, 1200, {markerStyle: style}, hook)
    const popup = marker.popup
    const pin = marker.options.icon.html
    assert.deepEqual(marker.options.icon.iconSize, style === 'plain' ? [36, 36] : [184, 184])
    hook.map.setZoom(11)
    assert.deepEqual(marker.options.icon.iconSize, [36, 36])
    let popupUpdates = 0
    hook.openPopup = {isOpen() { return true }, update() { popupUpdates++ }}
    hook.map.fitBounds = () => assert.fail('zooming must not reset the viewport')
    hook.map.setZoom(12)
    const size = style === 'plain' ? 36 : 136
    assert.deepEqual(marker.options.icon.iconSize, [size, size])
    assert.deepEqual(marker.options.icon.iconAnchor, style === 'plain' ? [18, 43] : [68, 144])
    assert.deepEqual(marker.options.icon.popupAnchor, style === 'plain' ? [0, -40] : [0, -148])
    assert.equal(marker.popup, popup)
    assert.equal(pin.children.at(-1).textContent, '2')
    assert.deepEqual(fallback.options.icon.iconSize, [36, 36])
    if (style !== 'plain') {
      assert.equal(pin.className, 'atlas-pin atlas-pin-thumbnail')
      assert.equal(pin.style.width, '136px')
      assert.equal(pin.children[0].style.width, '128px')
    }
    assert.ok(popupUpdates > 0)
    hook.map.setZoom(13)
    assert.deepEqual(marker.options.icon.iconSize, [size, size])
    hook.map.setZoom(14)
    const closeSize = style === 'plain' ? 36 : 184
    assert.deepEqual(marker.options.icon.iconSize, [closeSize, closeSize])
    assert.deepEqual(marker.options.icon.iconAnchor, style === 'plain' ? [18, 43] : [92, 192])
    assert.deepEqual(marker.options.icon.popupAnchor, style === 'plain' ? [0, -40] : [0, -196])
    assert.equal(marker.popup, popup)
    assert.equal(pin.children.at(-1).textContent, '2')
    assert.deepEqual(fallback.options.icon.iconSize, [36, 36])
    if (style !== 'plain') {
      assert.equal(pin.style.height, '184px')
      assert.equal(pin.children[0].style.height, '176px')
    }
    const changes = marker.iconChanges
    hook.map.setZoom(19)
    assert.equal(marker.iconChanges, changes)
    hook.map.setZoom(12)
    assert.deepEqual(marker.options.icon.iconSize, [size, size])
    hook.map.setZoom(11)
    assert.deepEqual(marker.options.icon.iconSize, [36, 36])
    assert.equal(pin.className, 'atlas-pin')
    hook.map.setZoom(6)
    assert.deepEqual(marker.options.icon.iconSize, [36, 36])
  }
})

test('image errors restore plain marker sizing even while zoomed in', () => {
  const hook = {}
  const [marker] = renderMarkers([meetup('Image', 101.68, {
    community_logo_url: `/media/meetups/${'b'.repeat(64)}`,
  })], 510, 1200, {markerStyle: 'community'}, hook)
  hook.map.setZoom(17)
  const image = marker.options.icon.html.children[0]
  image.listeners.error()
  assert.equal(image.hidden, true)
  assert.deepEqual(marker.options.icon.iconSize, [36, 36])
  assert.equal(marker.options.icon.html.className, 'atlas-pin')
  assert.deepEqual(marker.options.icon.iconAnchor, [18, 43])
  hook.map.setZoom(19)
  assert.deepEqual(marker.options.icon.iconSize, [36, 36])
})

test('marker sizing uses fixed zoom thresholds after settings edits and asynchronously fitting changed points', () => {
  const points = [meetup('Image', 101.68, {meetup_photo_url: `/media/meetups/${'c'.repeat(64)}`})]
  const hook = {}
  const markers = renderMarkers(points, 510, 1200, {markerStyle: 'plain'}, hook)
  hook.map.setZoom(12)
  hook.el.dataset.markerStyle = 'meetup'
  hook.updated()
  assert.deepEqual(markers.at(-1).options.icon.iconSize, [136, 136])

  hook.el.querySelector = () => ({textContent: JSON.stringify([...points, meetup('New location', 102)])})
  hook.map.fitBounds = () => {}
  hook.updated()
  hook.map.zoom = 6
  hook.map.fire('zoomend')
  hook.map.fire('moveend')
  const imageMarker = markers.at(-2)
  assert.deepEqual(imageMarker.options.icon.iconSize, [36, 36])
  hook.map.setZoom(8)
  assert.deepEqual(imageMarker.options.icon.iconSize, [36, 36])
  hook.map.setZoom(10)
  assert.deepEqual(imageMarker.options.icon.iconSize, [36, 36])
  hook.map.setZoom(12)
  assert.deepEqual(imageMarker.options.icon.iconSize, [136, 136])
  hook.map.setZoom(14)
  assert.deepEqual(imageMarker.options.icon.iconSize, [184, 184])
  hook.map.setZoom(17)
  assert.deepEqual(imageMarker.options.icon.iconSize, [184, 184])
})

test('saving marker settings redraws unchanged points without resetting the map viewport', () => {
  const points = [meetup('Same meetup', 101.68)]
  const hook = {}
  renderMarkers(points, 510, 1200, {}, hook)
  let boundsChanges = 0
  hook.map.fitBounds = () => boundsChanges++
  hook.el.dataset.markerColor = '#be123c'
  AtlasMap.updatePoints.call(hook)
  assert.equal(boundsChanges, 0)
  let clears = 0
  hook.markers.clearLayers = () => clears++
  AtlasMap.updatePoints.call(hook)
  assert.equal(clears, 0)
})

test('popup scrolling fits inside the mobile map at the initial zoom', () => {
  for (const height of [380, 260, 510]) {
    const [marker] = renderMarkers([meetup('Meetup', 101.68)], height)
    assert.ok(marker.config.maxHeight <= height - 80)
    assert.ok(marker.config.maxHeight <= 420)
  }
})

test('long descriptions remain complete and popup widths fit narrow mobile maps', () => {
  const description = 'Campfire event details\n\n'.repeat(100)
  for (const width of [280, 333, 1200]) {
    const [marker] = renderMarkers([meetup('Long meetup', 101.68, {
      description, address: 'Meetup venue', campfire_url: 'https://campfire.nianticlabs.com',
    })], 380, width)
    const content = marker.popup.children[0].children
    assert.equal(content.find(child => child.textContent === description).textContent, description)
    assert.equal(content.at(-1).textContent, 'View on Campfire')
    assert.ok(marker.config.minWidth <= width - 70)
  }
})

test('popup cover photos load safely and missing photos do not hide meetup details', () => {
  const markers = renderMarkers([
    meetup('<img onerror=alert(1)>', 101.68, {cover_photo_url: `/media/meetups/${'a'.repeat(64)}`}),
    meetup('No photo', 101.70, {cover_photo_url: 'javascript:alert(1)'}),
  ])
  const image = markers[0].popup.children[0].children[0]
  assert.equal(image.tag, 'img')
  assert.equal(image.src, `/media/meetups/${'a'.repeat(64)}`)
  assert.equal(image.referrerPolicy, 'no-referrer')
  assert.equal(markers[0].popup.children[0].children[1].textContent, '<img onerror=alert(1)>')
  image.listeners.error()
  assert.equal(image.hidden, true)
  assert.equal(markers[1].popup.children[0].children[0].tag, 'h3')
})


test('popup displays the host name and optional safe avatar', () => {
  const markers = renderMarkers([
    meetup('Hosted meetup', 101.68, {host_name: '<b>Trainer</b>', host_avatar_url: `/media/meetups/${'b'.repeat(64)}`}),
    meetup('Name only', 101.70, {host_name: 'Trainer', host_avatar_url: 'javascript:alert(1)'}),
  ])
  const host = markers[0].popup.children[0].children[1]
  assert.equal(host.className, 'atlas-meetup-host')
  assert.equal(host.children[0].src, `/media/meetups/${'b'.repeat(64)}`)
  assert.equal(host.children[1].textContent, 'Hosted by <b>Trainer</b>')
  const nameOnly = markers[1].popup.children[0].children[1]
  assert.equal(nameOnly.children.length, 1)
  assert.equal(nameOnly.children[0].textContent, 'Hosted by Trainer')
})

test('remote cover URLs are never requested by the browser', () => {
  const markers = renderMarkers([meetup('Remote image', 101.68, {cover_photo_url: 'https://cdn.example.com/remote.jpg'})])
  assert.equal(markers[0].popup.children[0].children[0].tag, 'h3')
})

test('processed cover photos and host avatars appear in the same popup', () => {
  const cover = `/media/meetups/${'c'.repeat(64)}?v=2`
  const avatar = `/media/meetups/${'d'.repeat(64)}?v=2`
  const [marker] = renderMarkers([meetup('Processed meetup', 101.68, {
    cover_photo_url: cover, host_avatar_url: avatar, host_name: 'Trainer',
  })])
  const section = marker.popup.children[0]
  assert.equal(section.children[0].src, cover)
  assert.equal(section.children[1].textContent, 'Processed meetup')
  assert.equal(section.children[2].children[0].src, avatar)
  assert.equal(section.children[2].children[1].textContent, 'Hosted by Trainer')
})

test('popup images reject unexpected queries and external addresses', () => {
  for (const url of [
    `/media/meetups/${'c'.repeat(64)}?v=3`,
    `/media/meetups/${'c'.repeat(64)}?v=1&redirect=https://example.com`,
    `https://example.com/media/meetups/${'c'.repeat(64)}?v=1`,
  ]) {
    const [marker] = renderMarkers([meetup('Invalid image', 101.68, {
      cover_photo_url: url, host_avatar_url: url, host_name: 'Trainer',
    })])
    const section = marker.popup.children[0]
    assert.equal(section.children[0].tag, 'h3')
    assert.equal(section.children[1].children.length, 1)
    assert.equal(section.children[1].children[0].textContent, 'Hosted by Trainer')
  }
})
