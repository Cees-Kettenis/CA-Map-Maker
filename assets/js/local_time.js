// Let Intl use the viewer's browser locale and time zone, including daylight saving.
export function formatLocalTime(value, timeZone) {
  if (!value) return ''
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return ''
  return new Intl.DateTimeFormat(undefined, {
    year: 'numeric', month: 'short', day: 'numeric',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
    ...(timeZone ? {timeZone} : {}),
  }).format(date)
}

export function formatMeetupTime(startsAt, endsAt, timeZone) {
  const start = formatLocalTime(startsAt, timeZone)
  if (!start || !endsAt) return start
  const end = new Date(endsAt)
  if (Number.isNaN(end.getTime())) return start
  const endTime = new Intl.DateTimeFormat(undefined, {
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
    ...(timeZone ? {timeZone} : {}),
  }).format(end)
  return `${start}–${endTime}`
}

export const LocalTime = {
  mounted() { this.format() },
  updated() { this.format() },
  format() {
    const text = formatMeetupTime(this.el.dateTime, this.el.dataset?.endsAt)
    if (text) this.el.textContent = text
  },
}
