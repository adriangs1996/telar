.pragma library

// Formats a mod's `elapsed` element: whole seconds, then minutes, hours and days.
function elapsed(since, now) {
    const seconds = Math.max(0, Math.floor(now / 1000 - since));
    if (seconds < 60) return seconds + "s";
    if (seconds < 3600) return Math.floor(seconds / 60) + "m";
    if (seconds < 86400) return Math.floor(seconds / 3600) + "h";
    return Math.floor(seconds / 86400) + "d";
}

const weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

function pad(value) {
    return value < 10 ? "0" + value : "" + value;
}

// The `ui.clock` conversions, so a mod's clock reads like a bar clock.
function clock(format, now) {
    const date = new Date(now);
    const hour = date.getHours();
    const values = {
        "H": pad(hour), "M": pad(date.getMinutes()), "S": pad(date.getSeconds()),
        "I": pad(hour % 12 === 0 ? 12 : hour % 12), "p": hour < 12 ? "AM" : "PM",
        "d": pad(date.getDate()), "e": ("" + date.getDate()).padStart(2, " "), "m": pad(date.getMonth() + 1),
        "y": pad(date.getFullYear() % 100), "Y": "" + date.getFullYear(),
        "a": weekdays[date.getDay()].slice(0, 3), "A": weekdays[date.getDay()],
        "b": months[date.getMonth()].slice(0, 3), "B": months[date.getMonth()], "%": "%",
    };
    let result = "";
    for (let index = 0; index < format.length; ++index) {
        if (format[index] === "%" && index + 1 < format.length) {
            const value = values[format[++index]];
            result += value === undefined ? "%" + format[index] : value;
        } else {
            result += format[index];
        }
    }
    return result;
}
