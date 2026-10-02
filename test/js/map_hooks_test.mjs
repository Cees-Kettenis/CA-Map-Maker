import test from 'node:test'
import assert from 'node:assert/strict'
import {AtlasMap} from '../../assets/js/map_hooks.js'

function renderMarkers(points) {
  const markers = []
  globalThis.document = {
    createElement(tag) {
      return {tag, children: [], listeners: {}, appendChild(child) { this.children.push(child) },
        addEventListener(event, handler) { this.listeners[event] = handler }}
    },
  }
  globalThis.window = {L: {
    divIcon(options) { return options },
    marker(coordinates, options) {
      const marker = {coordinates, options, bindPopup(popup, config) { this.popup = popup; this.config = config; return this }, addTo() { return this }}
      markers.push(marker)
      return marker
    },
  }}
  AtlasMap.updatePoints.call({
    el: {querySelector() { return {textContent: JSON.stringify(points)} }},
    markers: {clearLayers() {}, getBounds() { return [] }},
    map: {fitBounds() {}},
  })
  return markers
}

const meetup = (title, longitude, extra = {}) => ({title, latitude: 3.139, longitude, ...extra})

test('meetups at the same coordinates share a marker with the next meetup first', () => {
  const markers = renderMarkers([meetup('Soonest', 101.68), meetup('Another location', 101.70), meetup('Later at the same place', 101.68)])
  assert.equal(markers.length, 2)
  assert.deepEqual(markers[0].popup.children.map(section => section.children[0].textContent), ['Soonest', 'Later at the same place'])
  assert.match(markers[0].options.title, /^Soonest/)
  assert.match(markers[0].options.icon.html, /atlas-pin-count">2/)
  assert.ok(markers[0].options.zIndexOffset > markers[1].options.zIndexOffset)
  assert.equal(markers[0].config.maxHeight, 420)
})

test('popup cover photos load safely and missing photos do not hide meetup details', () => {
  const markers = renderMarkers([
    meetup('<img onerror=alert(1)>', 101.68, {cover_photo_url: 'https://cdn.example.com/cover.jpg'}),
    meetup('No photo', 101.70, {cover_photo_url: 'javascript:alert(1)'}),
  ])
  const image = markers[0].popup.children[0].children[0]
  assert.equal(image.tag, 'img')
  assert.equal(image.src, 'https://cdn.example.com/cover.jpg')
  assert.equal(image.referrerPolicy, 'no-referrer')
  assert.equal(markers[0].popup.children[0].children[1].textContent, '<img onerror=alert(1)>')
  image.listeners.error()
  assert.equal(image.hidden, true)
  assert.equal(markers[1].popup.children[0].children[0].tag, 'h3')
})


test('popup displays the host name and optional safe avatar', () => {
  const markers = renderMarkers([
    meetup('Hosted meetup', 101.68, {host_name: '<b>Trainer</b>', host_avatar_url: 'https://cdn.example.com/avatar.jpg'}),
    meetup('Name only', 101.70, {host_name: 'Trainer', host_avatar_url: 'javascript:alert(1)'}),
  ])
  const host = markers[0].popup.children[0].children[1]
  assert.equal(host.className, 'atlas-meetup-host')
  assert.equal(host.children[0].src, 'https://cdn.example.com/avatar.jpg')
  assert.equal(host.children[1].textContent, 'Hosted by <b>Trainer</b>')
  const nameOnly = markers[1].popup.children[0].children[1]
  assert.equal(nameOnly.children.length, 1)
  assert.equal(nameOnly.children[0].textContent, 'Hosted by Trainer')
})
