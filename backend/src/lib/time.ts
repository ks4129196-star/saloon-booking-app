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
