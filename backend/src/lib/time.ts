/** Length of one bookable slot, in minutes. The app uses the same value. */
export const SLOT_MINUTES = 30;

/** How far ahead customers can book. */
export const BOOKING_WINDOW_DAYS = 14;

/** Local wall-clock time of [instant] in [timeZone]. */
export function localParts(instant: Date, timeZone: string) {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone,
    hourCycle: 'h23',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  }).formatToParts(instant);
  const get = (type: string) => Number(parts.find((part) => part.type === type)?.value ?? 0);
  return {
    minuteOfDay: get('hour') * 60 + get('minute'),
    second: get('second'),
  };
}

/** Whether [timeZone] is a valid IANA zone such as "Asia/Kolkata". */
export function isValidTimeZone(timeZone: string): boolean {
  try {
    new Intl.DateTimeFormat('en', { timeZone });
    return true;
  } catch {
    return false;
  }
}

/** Minutes [timeZone] is ahead of UTC at [instant] (330 for India). */
function offsetMinutes(instant: Date, timeZone: string): number {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  }).formatToParts(instant);
  const get = (type: string) => Number(parts.find((part) => part.type === type)?.value ?? 0);
  const wall = Date.UTC(get('year'), get('month') - 1, get('day'), get('hour'), get('minute'));
  return Math.round((wall - Math.floor(instant.getTime() / 60_000) * 60_000) / 60_000);
}

/**
 * The instant at [minuteOfDay] on [date] ("2026-11-22") in [timeZone].
 * Corrected twice so it stays right across daylight-saving changes.
 */
export function zonedInstant(date: string, minuteOfDay: number, timeZone: string): Date {
  const [year, month, day] = date.split('-').map(Number) as [number, number, number];
  const wall = Date.UTC(year, month - 1, day) + minuteOfDay * 60_000;
  let instant = wall - offsetMinutes(new Date(wall), timeZone) * 60_000;
  instant = wall - offsetMinutes(new Date(instant), timeZone) * 60_000;
  return new Date(instant);
}

/** The calendar date ("2026-11-22") of [instant] in [timeZone]. */
export function localDate(instant: Date, timeZone: string): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(instant);
}

/** How many 30-minute blocks an appointment of [minutes] needs. */
export const slotsNeeded = (minutes: number) => Math.max(1, Math.ceil(minutes / SLOT_MINUTES));
