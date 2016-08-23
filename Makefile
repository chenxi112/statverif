.PHONY:

OCAMLYACC ?= ocamlyacc
OCAMLLEX ?= ocamllex
OCAML ?= ocamlc
OCAMLDEP ?= ocamldep
PATHFLAGS = -I $(SRCDIR)
OCAMLFLAGS ?= -g -w p -annot

SRCDIR = src

proverif_SOURCES = $(addprefix $(SRCDIR)/,\
	misc.mli misc.ml                                                              \
	parsing_helper.mli parsing_helper.ml stringmap.mli                            \
	stringmap.ml ptree.mli piptree.mli pitptree.mli types.mli pitypes.mli         \
	funmap.mli funmap.ml param.mli param.ml parser.mli parser.ml lexer.ml         \
	debug.ml \
	queue.mli queue.ml terms.mli terms.ml termslinks.mli termslinks.ml            \
	display.mli display.ml history.mli history.ml termsEq.mli termsEq.ml          \
	pievent.mli pievent.ml weaksecr.mli weaksecr.ml noninterf.mli noninterf.ml    \
	selfun.mli selfun.ml rules.mli rules.ml syntax.mli syntax.ml tsyntax.mli      \
	tsyntax.ml piparser.mli piparser.ml pilexer.ml pitparser.mli pitparser.ml     \
	pitlexer.ml spassout.mli spassout.ml reduction_helper.mli                     \
	reduction_helper.ml simplify.mli simplify.ml pisyntax.mli pisyntax.ml         \
	pitsyntax.mli pitsyntax.ml pitransl.mli pitransl.ml pitranslweak.mli          \
	pitranslweak.ml destructor.mli destructor.ml reduction.mli reduction.ml       \
	reduction_bipro.mli reduction_bipro.ml piauth.mli piauth.ml main.ml)

proveriftotex_SOURCES = $(addprefix $(SRCDIR)/,\
	parsing_helper.mli parsing_helper.ml param.mli param.ml \
	piparser.mli piparser.ml pitparser.mli pitparser.ml \
	pilexer.ml pitlexer.ml \
	fileprint.ml lexertotex.ml pitlexertotex.ml proveriftotex.ml)

all: proverif proveriftotex

proverif_CMI := $(patsubst %.mli,%.cmi,$(filter %.mli,$(proverif_SOURCES)))
proverif_OBJECTS := $(patsubst %.ml,%.cmo,$(filter %.ml,$(proverif_SOURCES)))
proverif: $(proverif_CMI) $(proverif_OBJECTS)
	$(OCAML) $(PATHFLAGS) $(OCAMLFLAGS) -o $@ $(proverif_OBJECTS)

proveriftotex_CMI := $(patsubst %.mli,%.cmi,$(filter %.mli,$(proveriftotex_SOURCES)))
proveriftotex_OBJECTS := $(patsubst %.ml,%.cmo,$(filter %.ml,$(proveriftotex_SOURCES)))
proveriftotex: $(proveriftotex_CMI) $(proveriftotex_OBJECTS)
	$(OCAML) $(PATHFLAGS) $(OCAMLFLAGS) -o $@ $(proveriftotex_OBJECTS)

%.cmi: %.mli
	$(OCAML) -c $(PATHFLAGS) $(OCAMLFLAGS) $<

# .ml files need their corresponding .mli files compiled first.
%.cmo: %.ml %.cmi
	$(OCAML) -c $(PATHFLAGS) $(OCAMLFLAGS) $*.ml

# Some .ml files have no corresponding .mli files.
# Find these and use a separate rule for them.
$(strip                                                                    \
  $(foreach i,$(filter %.ml,$(proverif_SOURCES) $(proveriftotex_SOURCES)), \
    $(if $(filter $(i:.ml=.mli),                                           \
      $(proverif_SOURCES) $(proveriftotex_SOURCES)),,$(i:.ml=.cmo))        \
  ) $(patsubst %.mll,%.cmo,$(wildcard $(SRCDIR)/*.mll))                    \
): %.cmo: %.ml
	$(OCAML) -c $(PATHFLAGS) $(OCAMLFLAGS) $*.ml

.PHONY: clean
CLEANFILES := proverif proveriftotex \
	$(proverif_CMI) $(proverif_OBJECTS) \
	$(proveriftotex_CMI) $(proveriftotex_OBJECTS) \
	$(proverif_OBJECTS:.cmo=.o) $(proverif_OBJECTS:.cmo=.o)
ACCIDENT := $(filter %.ml,$(CLEANFILES)) $(filter %.mli,$(CLEANFILES))
ifneq ($(strip $(ACCIDENT)),)
	junk := $(error Source files in CLEANFILES! $(ACCIDENT))
endif


install: proverif
	install proverif /usr/local/bin/statverif

clean:
	$(RM) $(CLEANFILES)

###  Lexer/parser  ###

%.ml %.mli: %.mly
	$(OCAMLYACC) $<

%.ml: %.mll
	$(OCAMLLEX) $<

###  Dependencies  ###

.PHONY: depend
depend:
	$(OCAMLDEP) $(PATHFLAGS) $(proverif_SOURCES) $(proveriftotex_SOURCES) \
	    | sed -r 's/^([^\.:]+)\.cmo:(.*)\1\.cmi/\1\.cmo \1\.cmi:\2/' >.dependencies

-include .dependencies
