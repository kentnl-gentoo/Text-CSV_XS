/* -*- C -*-
 *
 *  Copyright (c) 1998 Jochen Wiedmann. All rights reserved.
 *  This program is free software; you can redistribute it and/or
 *  modify it under the same terms as Perl itself.
 *
 *
 ***************************************************************************
 *
 *  HISTORY
 *
 *  Written by:
 *     Jochen Wiedmann <joe@ispsoft.de>
 *
 *  Version 0.10  03-May-1998  Initial version
 *
 **************************************************************************/

#include <EXTERN.h>
#include <perl.h>
#include <XSUB.h>


typedef struct {
    HV* self;
    char quoteChar;
    char escapeChar;
    char sepChar;
    int binary;
    char buffer[1024];
    STRLEN used;
    STRLEN size;
    char* bptr;
    int useIO;
    SV* tmp;
} csv_t;


static void SetupCsv(csv_t* csv, HV* self) {
    SV** svp;
    STRLEN len;
    char* ptr;

    csv->quoteChar = '"';
    if ((svp = hv_fetch(self, "quote_char", 10, 0))  &&  *svp) {
        if (!SvOK(*svp)) {
	    csv->quoteChar = '\0';
	} else {
	    ptr = SvPV(*svp, len);
	    csv->quoteChar = len ? *ptr : '\0';
	}
    }
    csv->escapeChar = '"';
    if ((svp = hv_fetch(self, "escape_char", 11, 0))  &&  *svp
	&&  SvOK(*svp)) {
        ptr = SvPV(*svp, len);
	if (len) {
	    csv->escapeChar = *ptr;
	}
    }
    csv->sepChar = ',';
    if ((svp = hv_fetch(self, "sep_char", 8, 0))  &&  *svp  &&	SvOK(*svp)) {
        ptr = SvPV(*svp, len);
	if (len) {
	    csv->sepChar = *ptr;
	}
    }
    csv->binary = 0;
    if ((svp = hv_fetch(self, "binary", 6, 0))  &&  *svp) {
        csv->binary = SvTRUE(*svp);
    }
    csv->self = self;
    csv->used = 0;
}


static
int Print(csv_t* csv, SV* dst) {
    int result;

    if (csv->useIO) {
        SV* tmp = newSVpv(csv->buffer, csv->used);
	dSP;                                              
	PUSHMARK(sp);
	EXTEND(sp, 2);
	PUSHs((dst));
	PUSHs(tmp);
	PUTBACK;
	result = perl_call_method("print", G_SCALAR);
	SPAGAIN;
	if (result) {
	    result = POPi;
	}
	PUTBACK;
	SvREFCNT_dec(tmp);
    } else {
        sv_catpvn(SvRV(dst), csv->buffer, csv->used);
	result = TRUE;
    }
    csv->used = 0;
    return result;
}


#define CSV_PUT(csv, dst, c)                                \
    if ((csv)->used == sizeof((csv)->buffer)-1) {           \
        Print((csv), (dst));                                \
    }                                                       \
    (csv)->buffer[(csv)->used++] = (c);


static int Encode(csv_t* csv, SV* dst, AV* fields, SV* eol) {
    int i;
    for (i = 0;  i <= av_len(fields);  i++) {
	SV** svp;
	if (i > 0) {
	    CSV_PUT(csv, dst, csv->sepChar);
	}
	if ((svp = av_fetch(fields, i, 0))  &&  *svp  &&  SvOK(*svp)) {
	    STRLEN len;
	    char* ptr = SvPV(*svp, len);
	    if (csv->quoteChar) {
	        CSV_PUT(csv, dst, csv->quoteChar);
	    }
	    while (len-- > 0) {
	        char c = *ptr++;
		int e = 0;
		if (!csv->binary  &&
		    (c != '\t'  &&  (c < '\040'  ||  c > '\176'))) {
		    SvREFCNT_inc(*svp);
		    if (!hv_store(csv->self, "_ERROR_INPUT", 12, *svp, 0)) {
		        SvREFCNT_dec(*svp);
		    }
		    return FALSE;
		}
		if (csv->quoteChar  &&  c == csv->quoteChar) {
		    e = 1;
		} else if (c == csv->escapeChar) {
		    e = 1;
		} else if (c == '\0') {
		    e = 1;
		    c = '0';
		}
		if (e) {
		    CSV_PUT(csv, dst, csv->escapeChar);
		}
		CSV_PUT(csv, dst, c);
	    }
	    if (csv->quoteChar) {
	        CSV_PUT(csv, dst, csv->quoteChar);
	    }
	}
    }
    if (eol && SvOK(eol)) {
        STRLEN len;
	char* ptr = SvPV(eol, len);
	while (len--) {
	    CSV_PUT(csv, dst, *ptr++);
	}
    }
    if (csv->used) {
        Print(csv, dst);
    }
    return TRUE;
}


static void DecodeError(csv_t* csv) {
    if(csv->tmp) {
        if (hv_store(csv->self, "_ERROR_INPUT", 12, csv->tmp, 0)) {
	    SvREFCNT_inc(csv->tmp);
	}
    }
}

static int CsvGet(csv_t* csv, SV* src) {
    if (!csv->useIO) {
        return EOF;
    }
    {
        int result;
        dSP;
	PUSHMARK(sp);
	EXTEND(sp, 1);
	PUSHs(src);
	PUTBACK;
	result = perl_call_method("getline", G_SCALAR);
	SPAGAIN;
	if (result) {
	    csv->tmp = POPs;
	} else {
	    csv->tmp = NULL;
	}
	PUTBACK;
    }
    if (csv->tmp  &&  SvOK(csv->tmp)) {
        csv->bptr = SvPV(csv->tmp, csv->size);
	csv->used = 0;
	if (csv->size) {
	    return ((unsigned char) csv->bptr[csv->used++]);
	}
    }
    return EOF;
}

#define ERROR_INSIDE_QUOTES                                        \
    SvREFCNT_dec(insideQuotes);                                    \
    DecodeError(csv);                                              \
    return FALSE;
#define ERROR_INSIDE_FIELD                                         \
    SvREFCNT_dec(insideField);                                     \
    DecodeError(csv);                                              \
    return FALSE;

#define CSV_PUT_SV(sv, c)                                          \
    len = SvCUR((sv));                                             \
    SvGROW((sv), len+2);                                           \
    *SvEND((sv)) = c;                                              \
    SvCUR_set((sv), len+1)

#define CSV_GET                                                    \
    ((c_ungetc != EOF) ? c_ungetc :                                \
     ((csv->used < csv->size) ?                                    \
      ((unsigned char) csv->bptr[(csv)->used++]) : CsvGet(csv, src)))

#define AV_PUSH(fields, sv)                                        \
    *SvEND(sv) = '\0';                                             \
    av_push(fields, sv);

static int Decode(csv_t* csv, SV* src, AV* fields) {
    int c;
    int c_ungetc = EOF;
    int waitingForField = 1;
    SV* insideQuotes = NULL;
    SV* insideField = NULL;
    STRLEN len;
    int seenSomething = FALSE;

    while ((c = CSV_GET)  !=  EOF) {
        seenSomething = TRUE;
restart:
        if (c == csv->sepChar) {
	    if (waitingForField) {
	        av_push(fields, newSVpv("", 0));
	    } else if (insideQuotes) {
	        CSV_PUT_SV(insideQuotes, c);
	    } else {
	        AV_PUSH(fields, insideField);
		insideField = NULL;
		waitingForField = 1;
	    }
	} else if (c == '\012') {
	    if (waitingForField) {
	        av_push(fields, newSVpv("", 0));
		return TRUE;
	    } else if (insideQuotes) {
	        if (!csv->binary) {
		    ERROR_INSIDE_QUOTES;
		}
		CSV_PUT_SV(insideQuotes, c);
	    } else {
	        AV_PUSH(fields, insideField);
		return TRUE;
	    }
	} else if (c == '\015') {
	    if (waitingForField) {
	        int c2 = CSV_GET;
		if (c2 == EOF) {
		    insideField = newSVpv("", 0);
		    waitingForField = 0;
		    goto restart;
		} else if (c2 == '\012') {
		    c = '\012';
		    goto restart;
		} else {
		    c_ungetc = c2;
		    insideField = newSVpv("", 0);
		    waitingForField = 0;
		    goto restart;
		}
	    } else if (insideQuotes) {
	        if (!csv->binary) {
		    ERROR_INSIDE_QUOTES;
		}
		CSV_PUT_SV(insideQuotes, c);
	    } else {
	        int c2 = CSV_GET;
		if (c2 == '\015') {
		    AV_PUSH(fields, insideField);
		    return TRUE;
		} else {
		    ERROR_INSIDE_FIELD;
		}
	    }
	} else if (c == csv->quoteChar) {
	    if (waitingForField) {
	        insideQuotes = newSVpv("", 0);
		waitingForField = 0;
	    } else if (insideQuotes) {
	        int c2;
	        if (c != csv->escapeChar) {
		    /* Field is terminated */
		    AV_PUSH(fields, insideQuotes);
		    insideQuotes = NULL;
		    waitingForField = 1;
		    c2 = CSV_GET;
		    if (c2 == csv->sepChar) {
		        continue;
		    } else if (c2 == EOF) {
		        return TRUE;
		    } else if (c2 == '\015') {
		        int c3 = CSV_GET;
			if (c3 == '\012') {
			    return TRUE;
			}
			DecodeError(csv);
			return FALSE;
		    } else if (c2 == '\012') {
		        return TRUE;
		    } else {
		        DecodeError(csv);
			return FALSE;
		    }
		}
		c2 = CSV_GET;
		if (c2 == EOF) {
		    AV_PUSH(fields, insideQuotes);
		    return TRUE;
		} else if (c2 == csv->sepChar) {
		    AV_PUSH(fields, insideQuotes);
		    insideQuotes = NULL;
		    waitingForField = 1;
		} else if (c2 == '0') {
		    CSV_PUT_SV(insideQuotes, (int) '\0');
		} else if (c2 == csv->quoteChar  ||  c2 == csv->sepChar) {
		    CSV_PUT_SV(insideQuotes, c2);
		} else if (c2 == '\012') {
		    AV_PUSH(fields, insideQuotes);
		    return TRUE;
		} else if (c2 == '\015') {
		    int c3 = CSV_GET;
		    if (c3 == '\012') {
		        AV_PUSH(fields, insideQuotes);
			return TRUE;
		    }
		    ERROR_INSIDE_QUOTES;
		} else {
		    ERROR_INSIDE_QUOTES;
		}
	    } else {
	        ERROR_INSIDE_FIELD;
	    }
	} else if (c == csv->escapeChar) {
	    /*  This means quoteChar != escapeChar  */
	    if (waitingForField) {
	        insideField = newSVpv("", 0);
		waitingForField = 0;
	    } else if (insideQuotes) {
	        int c2 = CSV_GET;
		if (c2 == EOF) {
		    ERROR_INSIDE_QUOTES;
		} else if (c2 == '0') {
		    CSV_PUT_SV(insideQuotes, (int) '\0');
		} else if (c2 == csv->quoteChar  ||  c2 == csv->sepChar) {
		    CSV_PUT_SV(insideQuotes, c2);
		} else {
		    ERROR_INSIDE_QUOTES;
		}
	    } else {
	        ERROR_INSIDE_FIELD;
	    }
	} else {
	    if (waitingForField) {
	        insideField = newSVpv("", 0);
		waitingForField = 0;
		goto restart;
	    } else if (insideQuotes) {
	        if (!csv->binary  &&
		    (c != '\011'  &&  (c < '\040'  ||  c > '\176'))) {
		    ERROR_INSIDE_QUOTES;
		}
		CSV_PUT_SV(insideQuotes, c);
	    } else {
	        if (!csv->binary  &&
		    (c != '\011'  &&  (c < '\040'  ||  c > '\176'))) {
		    ERROR_INSIDE_FIELD;
		}
		CSV_PUT_SV(insideField, c);
	    }
	}
    }

    if (waitingForField) {
        if (seenSomething) {
	    av_push(fields, newSVpv("", 0));
	}
    } else if (insideQuotes) {
        ERROR_INSIDE_QUOTES;
    } else if (insideField) {
        AV_PUSH(fields, insideField);
    }
    return TRUE;
}


MODULE = Text::CSV_XS		PACKAGE = Text::CSV_XS

PROTOTYPES: ENABLE


SV*
Encode(self, dst, fields, useIO, eol)
    SV* self
    SV* dst
    SV* fields
    bool useIO
    SV* eol
  PROTOTYPE: $$$$
  PPCODE:
    {
        csv_t csv;
	HV* hv;
	AV* av;

	if (!self  ||  !SvOK(self)  ||  !SvROK(self)
	    ||  SvTYPE(SvRV(self)) != SVt_PVHV) {
	    croak("self is not a hash ref");
	} else {
	    hv = (HV*) SvRV(self);
	}
	if (!fields  ||  !SvOK(fields)  ||  !SvROK(fields)
	    ||  SvTYPE(SvRV(fields)) != SVt_PVAV) {
	    croak("fields is not an array ref");
	} else {
	    av = (AV*) SvRV(fields);
	}

	SetupCsv(&csv, hv);
        csv.useIO = useIO;
	ST(0) = Encode(&csv, dst, av, eol) ? &sv_yes : &sv_undef;
	XSRETURN(1);
    }


SV*
Decode(self, src, fields, useIO)
    SV* self
    SV* src
    SV* fields
    bool useIO
  PROTOTYPE: $$$$
  PPCODE:
    {
        csv_t csv;
	HV* hv;
	AV* av;

	if (!self  ||  !SvOK(self)  ||  !SvROK(self)
	    ||  SvTYPE(SvRV(self)) != SVt_PVHV) {
	    croak("self is not a hash ref");
	} else {
	    hv = (HV*) SvRV(self);
	}
	if (!fields  ||  !SvOK(fields)  ||  !SvROK(fields)
	    ||  SvTYPE(SvRV(fields)) != SVt_PVAV) {
	    croak("fields is not an array ref");
	} else {
	    av = (AV*) SvRV(fields);
	}

	SetupCsv(&csv, hv);
	if ((csv.useIO = useIO)) {
	    csv.tmp = NULL;
	    csv.size = 0;
	} else {
	    STRLEN size;
	    csv.tmp = src;
	    csv.bptr = SvPV(src, size);
	    csv.size = size;
	}
	ST(0) = Decode(&csv, src, av) ? &sv_yes : &sv_undef;
	XSRETURN(1);
    }


