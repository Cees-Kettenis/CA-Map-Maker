import test from 'node:test'
import assert from 'node:assert/strict'
import {formatLocalTime, formatMeetupTime, LocalTime} from '../../assets/js/local_time.js'

// Both viewers see the same instant. The UK offset changes with daylight saving.
test('meetup times use Malaysia and UK time zones and daylight saving', () => {
  assert.match(formatLocalTime('2026-10-03T06:00:00Z', 'Asia/Kuala_Lumpur'), /14:00/)
  assert.match(formatLocalTime('2026-10-03T06:00:00Z', 'Europe/London'), /07:00/)
  assert.match(formatLocalTime('2026-12-03T06:00:00Z', 'Europe/London'), /06:00/)
})

test('the local date moves to the next day when a timestamp crosses midnight', () => {
  const nextDay = new Intl.DateTimeFormat(undefined, {year: 'numeric', month: 'short', day: 'numeric', timeZone: 'UTC'}).format(new Date('2026-10-04T00:00:00Z'))
  assert.ok(formatLocalTime('2026-10-03T20:00:00Z', 'Asia/Kuala_Lumpur').includes(nextDay))
  assert.match(formatLocalTime('2026-10-03T20:00:00Z', 'Asia/Kuala_Lumpur'), /04:00/)
  assert.match(formatLocalTime('2026-10-03T20:00:00Z', 'Europe/London'), /21:00/)
  assert.equal(formatLocalTime(null), '')
  assert.equal(formatLocalTime('invalid'), '')
})

test('card timestamps keep their local format after LiveView updates', () => {
  const hook = {...LocalTime, el: {dateTime: '2026-10-03T06:00:00Z', textContent: 'UTC fallback'}}
  hook.mounted()
  assert.equal(hook.el.textContent, formatLocalTime(hook.el.dateTime))
  hook.el.dateTime = '2026-10-04T07:00:00Z'
  hook.el.textContent = 'new UTC fallback'
  hook.updated()
  assert.equal(hook.el.textContent, formatLocalTime(hook.el.dateTime))
})

test('meetup ranges show one local date without zone labels', () => {
  const range = formatMeetupTime('2026-10-03T05:00:00Z', '2026-10-03T09:00:00Z', 'Asia/Kuala_Lumpur')
  assert.match(range, /13:00–17:00$/)
  assert.equal((range.match(/2026/g) || []).length, 1)
  assert.doesNotMatch(range, /GMT|UTC/)
  assert.match(formatMeetupTime('2026-10-03T05:00:00Z', null, 'Asia/Kuala_Lumpur'), /13:00$/)
})

 test('card hooks read the end timestamp and keep the range after patches', () => {
  const hook = {...LocalTime, el: {dateTime: '2026-10-03T05:00:00Z', dataset: {endsAt: '2026-10-03T09:00:00Z'}}}
  hook.mounted()
  assert.equal(hook.el.textContent, formatMeetupTime(hook.el.dateTime, hook.el.dataset.endsAt))
  hook.el.dataset.endsAt = '2026-10-03T10:00:00Z'
  hook.updated()
  assert.equal(hook.el.textContent, formatMeetupTime(hook.el.dateTime, hook.el.dataset.endsAt))
})
