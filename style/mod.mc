// style — packed TextStyle / TermColor (lifted from jem syntax, no highlighter).
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

enum TermColor {
	TermColorBlack = 0,
	TermColorRed = 1,
	TermColorGreen = 2,
	TermColorYellow = 3,
	TermColorBlue = 4,
	TermColorMagenta = 5,
	TermColorCyan = 6,
	TermColorWhite = 7,
	TermColorDefault = 16,
	TermColorBase03 = 17,
	TermColorBase02 = 18,
	TermColorBase01 = 19,
	TermColorBase00 = 20,
	TermColorBase0 = 21,
	TermColorBase1 = 22,
	TermColorBase2 = 23,
	TermColorBase3 = 24
};

enum TextStyleBits {
	TextStyleFgShift = 0,
	TextStyleBgShift = 5,
	TextStyleColorMask = 0x001F,
	TextStyleBold = 0x0400,
	TextStyleUnderline = 0x0800,
	TextStyleReverse = 0x1000,
};

struct TextStyle {
	uint16_t bits;
};

TextStyle TextStyleDefault = {
	.bits = (uint16_t)(((uint16_t)TermColorDefault <<
		(uint16_t)TextStyleFgShift) | ((uint16_t)TermColorDefault <<
		(uint16_t)TextStyleBgShift)),
};

TextStyle text_style_make(TermColor fg, TermColor bg, uint16_t flags) {
	TextStyle s = {
		.bits = (uint16_t)((((uint16_t)fg) & (uint16_t)TextStyleColorMask) <<
			(uint16_t)TextStyleFgShift |
			(((uint16_t)bg) & (uint16_t)TextStyleColorMask) <<
			(uint16_t)TextStyleBgShift |
			flags)
	};
	return s;
}

TermColor text_style_fg(TextStyle style) {
	return (TermColor)((style.bits >> (uint16_t)TextStyleFgShift) &
		(uint16_t)TextStyleColorMask);
}

TermColor text_style_bg(TextStyle style) {
	return (TermColor)((style.bits >> (uint16_t)TextStyleBgShift) &
		(uint16_t)TextStyleColorMask);
}

bool text_style_eq(TextStyle a, TextStyle b) {
	return a.bits == b.bits;
}
