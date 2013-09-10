/*	$OpenBSD$	*/

/*
 * Copyright (c) 2008 Gilles Chehade <gilles@poolp.org>
 * Copyright (c) 2008 Pierre-Yves Ritschard <pyr@openbsd.org>
 * Copyright (c) 2002, 2003, 2004 Henning Brauer <henning@openbsd.org>
 * Copyright (c) 2001 Markus Friedl.  All rights reserved.
 * Copyright (c) 2001 Daniel Hartmeier.  All rights reserved.
 * Copyright (c) 2001 Theo de Raadt.  All rights reserved.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

%{
#include "includes.h"

#include <sys/types.h>
#include <sys/time.h>
#include <sys/queue.h>
#include <sys/tree.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/ioctl.h>

#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <ctype.h>
#include <err.h>
#include <errno.h>
#include <event.h>
#include <ifaddrs.h>
#include <imsg.h>
#include <inttypes.h>
#include <netdb.h>
#include <paths.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <unistd.h>
#ifdef HAVE_UTIL_H
#include <util.h>
#endif

#include <openssl/ssl.h>

#include "smtpd.h"
#include "ssl.h"
#include "log.h"

TAILQ_HEAD(files, file)		 files = TAILQ_HEAD_INITIALIZER(files);
static struct file {
	TAILQ_ENTRY(file)	 entry;
	FILE			*stream;
	char			*name;
	int			 lineno;
	int			 errors;
} *file, *topfile;
struct file	*pushfile(const char *, int);
int		 popfile(void);
int		 check_file_secrecy(int, const char *);
int		 yyparse(void);
int		 yylex(void);
int		 kw_cmp(const void *, const void *);
int		 lookup(char *);
int		 lgetc(int);
int		 lungetc(int);
int		 findeol(void);
int		 yyerror(const char *, ...)
    __attribute__ ((format (printf, 1, 2)));

TAILQ_HEAD(symhead, sym)	 symhead = TAILQ_HEAD_INITIALIZER(symhead);
struct sym {
	TAILQ_ENTRY(sym)	 entry;
	int			 used;
	int			 persist;
	char			*nam;
	char			*val;
};
int		 symset(const char *, const char *, int);
char		*symget(const char *);

struct smtpd		*conf = NULL;
static int		 errors = 0;

struct table		*table = NULL;
struct rule		*rule = NULL;
struct listener		 l;
struct mta_limits	*limits;
static struct ssl      	*pki_ssl;

static void config_listener(struct listener *,  const char *, const char *,
    const char *, in_port_t, const char *, uint16_t, const char *);
struct listener	*host_v4(const char *, in_port_t);
struct listener	*host_v6(const char *, in_port_t);
int		 host_dns(const char *, const char *, const char *,
		    struct listenerlist *, int, in_port_t, const char *,
		    uint16_t, const char *);
int		 host(const char *, const char *, const char *,
    struct listenerlist *, int, in_port_t, const char *, uint16_t, const char *);
int		 interface(const char *, int, const char *, const char *,
    struct listenerlist *, int, in_port_t, const char *, uint16_t, const char *);
void		 set_localaddrs(void);
int		 delaytonum(char *);
int		 is_if_in_group(const char *, const char *);

typedef struct {
	union {
		int64_t		 number;
		struct table	*table;
		char		*string;
		struct host	*host;
		struct mailaddr	*maddr;
	} v;
	int lineno;
} YYSTYPE;

%}

%token	AS QUEUE COMPRESSION ENCRYPTION MAXMESSAGESIZE MAXMTADEFERRED MAXSCHEDULERINFLIGHT LISTEN ON ANY PORT EXPIRE
%token	TABLE SSL SMTPS CERTIFICATE DOMAIN BOUNCEWARN LIMIT INET4 INET6
%token  RELAY BACKUP VIA DELIVER TO LMTP MAILDIR MBOX HOSTNAME HELO
%token	ACCEPT REJECT INCLUDE ERROR MDA FROM FOR SOURCE MTA PKI
%token	ARROW AUTH TLS LOCAL VIRTUAL TAG TAGGED ALIAS FILTER KEY CA DHPARAMS
%token	AUTH_OPTIONAL TLS_REQUIRE USERBASE SENDER MASK_SOURCE VERIFY
%token	<v.string>	STRING
%token  <v.number>	NUMBER
%type	<v.table>	table
%type	<v.number>	port auth ssl size expire address_family mask_source
%type	<v.table>	tables tablenew tableref destination alias virtual usermapping userbase from sender
%type	<v.string>	pkiname tag tagged listen_helo
%%

grammar		: /* empty */
		| grammar '\n'
		| grammar include '\n'
		| grammar varset '\n'
		| grammar main '\n'
		| grammar table '\n'
		| grammar rule '\n'
		| grammar error '\n'		{ file->errors++; }
		;

include		: INCLUDE STRING		{
			struct file	*nfile;

			if ((nfile = pushfile($2, 0)) == NULL) {
				yyerror("failed to include file %s", $2);
				free($2);
				YYERROR;
			}
			free($2);

			file = nfile;
			lungetc('\n');
		}
		;

varset		: STRING '=' STRING		{
			if (symset($1, $3, 0) == -1)
				fatal("cannot store variable");
			free($1);
			free($3);
		}
		;

comma		: ','
		| nl
		| /* empty */
		;

optnl		: '\n' optnl
		|
		;

nl		: '\n' optnl
		;

size		: NUMBER		{
			if ($1 < 0) {
				yyerror("invalid size: %" PRId64, $1);
				YYERROR;
			}
			$$ = $1;
		}
		| STRING			{
			long long result;

			if (scan_scaled($1, &result) == -1 || result < 0) {
				yyerror("invalid size: %s", $1);
				free($1);
				YYERROR;
			}
			free($1);
			$$ = result;
		}
		;

port		: PORT STRING			{
			struct servent	*servent;

			servent = getservbyname($2, "tcp");
			if (servent == NULL) {
				yyerror("invalid port: %s", $2);
				free($2);
				YYERROR;
			}
			free($2);
			$$ = ntohs(servent->s_port);
		}
		| PORT NUMBER			{
			if ($2 <= 0 || $2 >= (int)USHRT_MAX) {
				yyerror("invalid port: %" PRId64, $2);
				YYERROR;
			}
			$$ = $2;
		}
		| /* empty */			{
			$$ = 0;
		}
		;

pkiname		: PKI STRING	{
			if (($$ = strdup($2)) == NULL) {
				yyerror("strdup");
				free($2);
				YYERROR;
			}
			free($2);
		}
		| /* empty */			{ $$ = NULL; }
		;

ssl		: SMTPS				{ $$ = F_SMTPS; }
		| SMTPS VERIFY 			{ $$ = F_SMTPS|F_TLS_VERIFY; }
		| TLS				{ $$ = F_STARTTLS; }
		| SSL				{ $$ = F_SSL; }
		| TLS_REQUIRE			{ $$ = F_STARTTLS|F_STARTTLS_REQUIRE; }
		| TLS_REQUIRE VERIFY   		{ $$ = F_STARTTLS|F_STARTTLS_REQUIRE|F_TLS_VERIFY; }
		| /* Empty */			{ $$ = 0; }
		;

auth		: AUTH				{
			$$ = F_AUTH|F_AUTH_REQUIRE;
		}
		| AUTH_OPTIONAL			{
			$$ = F_AUTH;
		}
		| AUTH tables  			{
			strlcpy(l.authtable, ($2)->t_name, sizeof l.authtable);
			$$ = F_AUTH|F_AUTH_REQUIRE;
		}
		| AUTH_OPTIONAL tables 		{
			strlcpy(l.authtable, ($2)->t_name, sizeof l.authtable);
			$$ = F_AUTH;
		}
		| /* empty */			{ $$ = 0; }
		;

tag		: TAG STRING			{
       			if (strlen($2) >= MAX_TAG_SIZE) {
       				yyerror("tag name too long");
				free($2);
				YYERROR;
			}

			$$ = $2;
		}
		| /* empty */			{ $$ = NULL; }
		;

tagged		: TAGGED STRING			{
			if (($$ = strdup($2)) == NULL) {
       				yyerror("strdup");
				free($2);
				YYERROR;
			}
			free($2);
		}
		| /* empty */			{ $$ = NULL; }
		;

expire		: EXPIRE STRING {
			$$ = delaytonum($2);
			if ($$ == -1) {
				yyerror("invalid expire delay: %s", $2);
				free($2);
				YYERROR;
			}
			free($2);
		}
		| /* empty */	{ $$ = conf->sc_qexpire; }
		;

bouncedelay	: STRING {
			time_t	d;
			int	i;

			d = delaytonum($1);
			if (d < 0) {
				yyerror("invalid bounce delay: %s", $1);
				free($1);
				YYERROR;
			}
			free($1);
			for (i = 0; i < MAX_BOUNCE_WARN; i++) {
				if (conf->sc_bounce_warn[i] != 0)
					continue;
				conf->sc_bounce_warn[i] = d;
				break;
			}
		}

bouncedelays	: bouncedelays ',' bouncedelay
		| bouncedelay
		| /* EMPTY */
		;

address_family	: INET4			{ $$ = AF_INET; }
		| INET6			{ $$ = AF_INET6; }
		| /* empty */		{ $$ = AF_UNSPEC; }
		;

listen_helo	: HOSTNAME STRING	{ $$ = $2; }
		| /* empty */		{ $$ = NULL; }
		;

opt_limit	: INET4 {
			limits->family = AF_INET;
		}
		| INET6 {
			limits->family = AF_INET6;
		}
		| STRING NUMBER {
			if (!limit_mta_set(limits, $1, $2)) {
				yyerror("invalid limit keyword");
				free($1);
				YYERROR;
			}
			free($1);
		}
		;

limits		: opt_limit limits
		| /* empty */
		;

opt_pki		: CERTIFICATE STRING {
			pki_ssl->ssl_cert_file = $2;
		}
		| KEY STRING {
			pki_ssl->ssl_key_file = $2;
		}
		| CA STRING {
			pki_ssl->ssl_ca_file = $2;
		}
		| DHPARAMS STRING {
			pki_ssl->ssl_dhparams_file = $2;
		}
		;

pki		: opt_pki pki
		|
		;


opt_relay_common: AS STRING	{
			struct mailaddr maddr, *maddrp;

			if (! text_to_mailaddr(&maddr, $2)) {
				yyerror("invalid parameter to AS: %s", $2);
				free($2);
				YYERROR;
			}
			free($2);

			if (maddr.user[0] == '\0' && maddr.domain[0] == '\0') {
				yyerror("invalid empty parameter to AS");
				YYERROR;
			}
			else if (maddr.domain[0] == '\0') {
				if (strlcpy(maddr.domain, conf->sc_hostname,
					sizeof (maddr.domain))
				    >= sizeof (maddr.domain)) {
					yyerror("hostname too long for AS parameter: %s",
					    conf->sc_hostname);
					YYERROR;
				}
			}
			rule->r_as = xmemdup(&maddr, sizeof (*maddrp), "parse relay_as: AS");
		}
		| SOURCE tables			{
			struct table	*t = $2;
			if (! table_check_use(t, T_DYNAMIC|T_LIST, K_SOURCE)) {
				yyerror("invalid use of table \"%s\" as "
				    "SOURCE parameter", t->t_name);
				YYERROR;
			}
			strlcpy(rule->r_value.relayhost.sourcetable, t->t_name,
			    sizeof rule->r_value.relayhost.sourcetable);
		}
		| HELO tables			{
			struct table	*t = $2;
			if (! table_check_use(t, T_DYNAMIC|T_HASH, K_ADDRNAME)) {
				yyerror("invalid use of table \"%s\" as "
				    "HELO parameter", t->t_name);
				YYERROR;
			}
			strlcpy(rule->r_value.relayhost.helotable, t->t_name,
			    sizeof rule->r_value.relayhost.helotable);
		}
		| PKI STRING {
			if (strlcpy(rule->r_value.relayhost.cert, $2,
				sizeof(rule->r_value.relayhost.cert))
			    >= sizeof(rule->r_value.relayhost.cert))
				fatal("certificate path too long");
			free($2);
		}
		;

opt_relay	: BACKUP STRING			{
			rule->r_value.relayhost.flags |= F_BACKUP;
			strlcpy(rule->r_value.relayhost.hostname, $2,
			    sizeof (rule->r_value.relayhost.hostname));
		}
		| BACKUP       			{
			rule->r_value.relayhost.flags |= F_BACKUP;
			strlcpy(rule->r_value.relayhost.hostname,
			    conf->sc_hostname,
			    sizeof (rule->r_value.relayhost.hostname));
		}
		| TLS       			{
			rule->r_value.relayhost.flags |= F_STARTTLS;
		}
		| TLS VERIFY			{
			rule->r_value.relayhost.flags |= F_STARTTLS|F_TLS_VERIFY;
		}
		;

relay		: opt_relay_common relay
		| opt_relay relay
		| /* empty */
		;

opt_relay_via	: AUTH tables {
			struct table   *t = $2;

			if (! table_check_use(t, T_DYNAMIC|T_HASH, K_CREDENTIALS)) {
				yyerror("invalid use of table \"%s\" as AUTH parameter",
				    t->t_name);
				YYERROR;
			}
			strlcpy(rule->r_value.relayhost.authtable, t->t_name,
			    sizeof(rule->r_value.relayhost.authtable));
		}
		| VERIFY {
			if (!(rule->r_value.relayhost.flags & F_SSL)) {
				yyerror("cannot \"verify\" with insecure protocol");
				YYERROR;
			}
			rule->r_value.relayhost.flags |= F_TLS_VERIFY;
		}
		;

relay_via	: opt_relay_common relay_via
		| opt_relay_via relay_via
		| /* empty */
		;

mask_source	: MASK_SOURCE	{ $$ = F_MASK_SOURCE; }
		|		{ $$ = 0; }
		;

main		: BOUNCEWARN {
			bzero(conf->sc_bounce_warn, sizeof conf->sc_bounce_warn);
		} bouncedelays
		| QUEUE COMPRESSION {
			conf->sc_queue_flags |= QUEUE_COMPRESSION;
		}
		| QUEUE ENCRYPTION {
			char	*password;

			password = getpass("queue key: ");
			if (password == NULL) {
				yyerror("getpass() error");
				YYERROR;
			}
			conf->sc_queue_key = strdup(password);
			bzero(password, strlen(password));
			if (conf->sc_queue_key == NULL) {
				yyerror("memory exhausted");
				YYERROR;
			}
			conf->sc_queue_flags |= QUEUE_ENCRYPTION;

		}
		| QUEUE ENCRYPTION KEY STRING {
			char   *buf;
			char   *lbuf;
			size_t	len;

			if (strcasecmp($4, "stdin") == 0 ||
			    strcasecmp($4, "-") == 0) {
				lbuf = NULL;
				buf = fgetln(stdin, &len);
				if (buf[len - 1] == '\n') {
					lbuf = calloc(len, 1);
					memcpy(lbuf, buf, len-1);
				}
				else {
					lbuf = calloc(len+1, 1);
					memcpy(lbuf, buf, len);
				}
				conf->sc_queue_key = lbuf;
			}
			else
				conf->sc_queue_key = $4;
			conf->sc_queue_flags |= QUEUE_ENCRYPTION;
		}
		| EXPIRE STRING {
			conf->sc_qexpire = delaytonum($2);
			if (conf->sc_qexpire == -1) {
				yyerror("invalid expire delay: %s", $2);
				free($2);
				YYERROR;
			}
			free($2);
		}
		| MAXMESSAGESIZE size {
			conf->sc_maxsize = $2;
		}
		| MAXMTADEFERRED NUMBER  {
			conf->sc_mta_max_deferred = $2;
		} 
		| MAXSCHEDULERINFLIGHT NUMBER  {
			conf->sc_scheduler_max_inflight = $2;
		} 
		| LIMIT MTA FOR DOMAIN STRING {
			struct mta_limits	*d;

			limits = dict_get(conf->sc_limits_dict, $5);
			if (limits == NULL) {
				limits = xcalloc(1, sizeof(*limits), "mta_limits");
				dict_xset(conf->sc_limits_dict, $5, limits);
				d = dict_xget(conf->sc_limits_dict, "default");
				memmove(limits, d, sizeof(*limits));
			}
			free($5);
		} limits
		| LIMIT MTA {
			limits = dict_get(conf->sc_limits_dict, "default");
		} limits
		| LISTEN {
			bzero(&l, sizeof l);
		} ON STRING address_family port ssl pkiname auth tag listen_helo mask_source {
			char	       *ifx  = $4;
			int		family = $5;
			in_port_t	port = $6;
			uint16_t       	ssl  = $7;
			char	       *pki = $8;
			uint16_t       	auth = $9;
			char	       *tag  = $10;
			char	       *helo = $11;
			uint16_t       	masksrc = $12;
			uint16_t	flags;

			if (port != 0 && ssl == F_SSL) {
				yyerror("invalid listen option: tls/smtps on same port");
				YYERROR;
			}

			if (auth != 0 && !ssl) {
				yyerror("invalid listen option: auth requires tls/smtps");
				YYERROR;
			}

			if (pki && !ssl) {
				yyerror("invalid listen option: pki requires tls/smtps");
				YYERROR;
			}

			if (ssl && !pki) {
				yyerror("invalid listen option: tls/smtps requires pki");
				YYERROR;
			}

			flags = auth|masksrc;
			if (port == 0) {
				if (ssl & F_SMTPS) {
					if (! interface(ifx, family, tag, pki, conf->sc_listeners,
						MAX_LISTEN, 465, l.authtable, F_SMTPS|flags, helo)) {
						if (host(ifx, tag, pki, conf->sc_listeners,
							MAX_LISTEN, 465, l.authtable, ssl|flags, helo) <= 0) {
							yyerror("invalid virtual ip or interface: %s", ifx);
							YYERROR;
						}
					}
				}
				if (! ssl || (ssl & ~F_SMTPS)) {
					if (! interface(ifx, family, tag, pki, conf->sc_listeners,
						MAX_LISTEN, 25, l.authtable, (ssl&~F_SMTPS)|flags, helo)) {
						if (host(ifx, tag, pki, conf->sc_listeners,
							MAX_LISTEN, 25, l.authtable, ssl|flags, helo) <= 0) {
							yyerror("invalid virtual ip or interface: %s", ifx);
							YYERROR;
						}
					}
				}
			}
			else {
				if (! interface(ifx, family, tag, pki, conf->sc_listeners,
					MAX_LISTEN, port, l.authtable, ssl|auth, helo)) {
					if (host(ifx, tag, pki, conf->sc_listeners,
						MAX_LISTEN, port, l.authtable, ssl|flags, helo) <= 0) {
						yyerror("invalid virtual ip or interface: %s", ifx);
						YYERROR;
					}
				}
			}
		}
		| FILTER STRING			{
			struct filter *filter;
			struct filter *tmp;

			filter = xcalloc(1, sizeof *filter, "parse condition: FILTER");
			if (strlcpy(filter->name, $2, sizeof (filter->name))
			    >= sizeof (filter->name)) {
       				yyerror("Filter name too long: %s", filter->name);
				free($2);
				free(filter);
				YYERROR;
				
			}
			(void)snprintf(filter->path, sizeof filter->path,
			    PATH_FILTERS "/%s", filter->name);

			tmp = dict_get(&conf->sc_filters, filter->name);
			if (tmp == NULL)
				dict_set(&conf->sc_filters, filter->name, filter);
			else {
       				yyerror("ambiguous filter name: %s", filter->name);
				free($2);
				free(filter);
				YYERROR;
			}
			free($2);
		}
		| FILTER STRING STRING		{
			struct filter *filter;
			struct filter *tmp;

			filter = calloc(1, sizeof (*filter));
			if (filter == NULL ||
			    strlcpy(filter->name, $2, sizeof (filter->name))
			    >= sizeof (filter->name) ||
			    strlcpy(filter->path, $3, sizeof (filter->path))
			    >= sizeof (filter->path)) {
				free(filter);
				free($2);
				free($3);
				free(filter);
				YYERROR;
			}

			tmp = dict_get(&conf->sc_filters, filter->name);
			if (tmp == NULL)
				dict_set(&conf->sc_filters, filter->name, filter);
			else {
       				yyerror("ambiguous filter name: %s", filter->name);
				free($2);
				free($3);
				free(filter);
				YYERROR;
			}
			free($2);
			free($3);
		}
		| PKI STRING	{
			pki_ssl = dict_get(conf->sc_ssl_dict, $2);
			if (pki_ssl == NULL) {
				pki_ssl = xcalloc(1, sizeof *pki_ssl, "parse:pki");
				xlowercase(pki_ssl->ssl_name, $2, sizeof pki_ssl->ssl_name);
				dict_set(conf->sc_ssl_dict, pki_ssl->ssl_name, pki_ssl);
			}
			free($2);
		} pki
		;

table		: TABLE STRING STRING	{
			char *p, *backend, *config;

			p = $3;
			if (*p == '/') {
				backend = "static";
				config = $3;
			}
			else {
				backend = $3;
				config = NULL;
				for (p = $3; *p && *p != ':'; p++)
					;
				if (*p == ':') {
					*p = '\0';
					backend = $3;
					config  = p+1;
				}
			}
			if (config != NULL && *config != '/') {
				yyerror("invalid backend parameter for table: %s",
				    $2);
				free($2);
				free($3);
				YYERROR;
			}
			table = table_create(backend, $2, NULL, config);
			if (!table_config(table)) {
				yyerror("invalid backend configuration for table %s",
				    table->t_name);
				free($2);
				free($3);
				YYERROR;
			}
			free($2);
			free($3);
		}
		| TABLE STRING {
			table = table_create("static", $2, NULL, NULL);
			free($2);
		} '{' tableval_list '}' {
			table = NULL;
		}
		;

assign		: '=' | ARROW;

keyval		: STRING assign STRING		{
			table->t_type = T_HASH;
			table_add(table, $1, $3);
			free($1);
			free($3);
		}
		;

keyval_list	: keyval
		| keyval comma keyval_list
		;

stringel	: STRING			{
			table->t_type = T_LIST;
			table_add(table, $1, NULL);
			free($1);
		}
		;

string_list	: stringel
		| stringel comma string_list
		;

tableval_list	: string_list			{ }
		| keyval_list			{ }
		;

tablenew	: STRING			{
			struct table	*t;

			t = table_create("static", NULL, NULL, NULL);
			t->t_type = T_LIST;
			table_add(t, $1, NULL);
			free($1);
			$$ = t;
		}
		| '{'				{
			table = table_create("static", NULL, NULL, NULL);
		} tableval_list '}'		{
			$$ = table;
		}
		;

tableref       	: '<' STRING '>'       		{
			struct table	*t;

			if ((t = table_find($2, NULL)) == NULL) {
				yyerror("no such table: %s", $2);
				free($2);
				YYERROR;
			}
			free($2);
			$$ = t;
		}
		;

tables		: tablenew			{ $$ = $1; }
		| tableref			{ $$ = $1; }
		;

alias		: ALIAS tables			{
			struct table   *t = $2;

			if (! table_check_use(t, T_DYNAMIC|T_HASH, K_ALIAS)) {
				yyerror("invalid use of table \"%s\" as ALIAS parameter",
				    t->t_name);
				YYERROR;
			}

			$$ = t;
		}
		;

virtual		: VIRTUAL tables		{
			struct table   *t = $2;

			if (! table_check_use(t, T_DYNAMIC|T_HASH, K_ALIAS)) {
				yyerror("invalid use of table \"%s\" as VIRTUAL parameter",
				    t->t_name);
				YYERROR;
			}

			$$ = t;
		}
		;

usermapping	: alias		{
			rule->r_desttype = DEST_DOM;
			$$ = $1;
		}
		| virtual	{
			rule->r_desttype = DEST_VDOM;
			$$ = $1;
		}
		| /**/		{
			rule->r_desttype = DEST_DOM;
			$$ = 0;
		}
		;

userbase	: USERBASE tables	{
			struct table   *t = $2;

			if (! table_check_use(t, T_DYNAMIC|T_HASH, K_USERINFO)) {
				yyerror("invalid use of table \"%s\" as USERBASE parameter",
				    t->t_name);
				YYERROR;
			}

			$$ = t;
		}
		| /**/	{ $$ = table_find("<getpwnam>", NULL); }
		;

		


destination	: DOMAIN tables			{
			struct table   *t = $2;

			if (! table_check_use(t, T_DYNAMIC|T_LIST, K_DOMAIN)) {
				yyerror("invalid use of table \"%s\" as DOMAIN parameter",
				    t->t_name);
				YYERROR;
			}

			$$ = t;
		}
		| LOCAL		{ $$ = table_find("<localnames>", NULL); }
		| ANY		{ $$ = 0; }
		;


action		: userbase DELIVER TO MAILDIR			{
			rule->r_userbase = $1;
			rule->r_action = A_MAILDIR;
			if (strlcpy(rule->r_value.buffer, "~/Maildir",
			    sizeof(rule->r_value.buffer)) >=
			    sizeof(rule->r_value.buffer))
				fatal("pathname too long");
		}
		| userbase DELIVER TO MAILDIR STRING		{
			rule->r_userbase = $1;
			rule->r_action = A_MAILDIR;
			if (strlcpy(rule->r_value.buffer, $5,
			    sizeof(rule->r_value.buffer)) >=
			    sizeof(rule->r_value.buffer))
				fatal("pathname too long");
			free($5);
		}
		| userbase DELIVER TO LMTP STRING		{
			rule->r_userbase = $1;
			rule->r_action = A_LMTP;
			if (strchr($5, ':') || $5[0] == '/') {
				if (strlcpy(rule->r_value.buffer, $5,
					sizeof(rule->r_value.buffer))
					>= sizeof(rule->r_value.buffer))
					fatal("lmtp destination too long");
			} else
				fatal("invalid lmtp destination");
			free($5);
		}
		| userbase DELIVER TO MBOX			{
			rule->r_userbase = $1;
			rule->r_action = A_MBOX;
			if (strlcpy(rule->r_value.buffer, _PATH_MAILDIR "/%u",
			    sizeof(rule->r_value.buffer))
			    >= sizeof(rule->r_value.buffer))
				fatal("pathname too long");
		}
		| userbase DELIVER TO MDA STRING	       	{
			rule->r_userbase = $1;
			rule->r_action = A_MDA;
			if (strlcpy(rule->r_value.buffer, $5,
			    sizeof(rule->r_value.buffer))
			    >= sizeof(rule->r_value.buffer))
				fatal("command too long");
			free($5);
		}
		| RELAY relay {
			rule->r_action = A_RELAY;
		}
		| RELAY VIA STRING {
			rule->r_action = A_RELAYVIA;
			if (! text_to_relayhost(&rule->r_value.relayhost, $3)) {
				yyerror("error: invalid url: %s", $3);
				free($3);
				YYERROR;
			}
			free($3);
		} relay_via {
			/* no worries, F_AUTH cant be set without SSL */
			if (rule->r_value.relayhost.flags & F_AUTH) {
				if (rule->r_value.relayhost.authtable[0] == '\0') {
					yyerror("error: auth without auth table");
					YYERROR;
				}
			}
		}
		;

from		: FROM tables			{
			struct table   *t = $2;

			if (! table_check_use(t, T_DYNAMIC|T_LIST, K_NETADDR)) {
				yyerror("invalid use of table \"%s\" as FROM parameter",
				    t->t_name);
				YYERROR;
			}

			$$ = t;
		}
		| FROM ANY			{
			$$ = table_find("<anyhost>", NULL);
		}
		| FROM LOCAL			{
			$$ = table_find("<localhost>", NULL);
		}
		| /* empty */			{
			$$ = table_find("<localhost>", NULL);
		}
		;

sender		: SENDER tables			{
			struct table   *t = $2;

			if (! table_check_use(t, T_DYNAMIC|T_LIST, K_MAILADDR)) {
				yyerror("invalid use of table \"%s\" as SENDER parameter",
				    t->t_name);
				YYERROR;
			}

			$$ = t;
		}
		| /* empty */			{ $$ = NULL; }
		;

rule		: ACCEPT {
			rule = xcalloc(1, sizeof(*rule), "parse rule: ACCEPT");
		 } tagged from sender FOR destination usermapping action expire {

			rule->r_decision = R_ACCEPT;
			rule->r_sources = $4;
			rule->r_senders = $5;
			rule->r_destination = $7;
			rule->r_mapping = $8;
			if ($3) {
				if (strlcpy(rule->r_tag, $3, sizeof rule->r_tag)
				    >= sizeof rule->r_tag) {
					yyerror("tag name too long: %s", $3);
					free($3);
					YYERROR;
				}
				free($3);
			}
			rule->r_qexpire = $10;

			if (rule->r_mapping && rule->r_desttype == DEST_VDOM) {
				enum table_type type;

				switch (rule->r_action) {
				case A_RELAY:
				case A_RELAYVIA:
					type = T_LIST;
					break;
				default:
					type = T_HASH;
					break;
				}
				if (! table_check_service(rule->r_mapping, K_ALIAS) &&
				    ! table_check_type(rule->r_mapping, type)) {
					yyerror("invalid use of table \"%s\" as VIRTUAL parameter",
					    rule->r_mapping->t_name);
					YYERROR;
				}
			}

			TAILQ_INSERT_TAIL(conf->sc_rules, rule, r_entry);

			rule = NULL;
		}
		| REJECT {
			rule = xcalloc(1, sizeof(*rule), "parse rule: REJECT");
		} tagged from sender FOR destination usermapping {
			rule->r_decision = R_REJECT;
			rule->r_sources = $4;
			rule->r_senders = $5;
			rule->r_destination = $7;
			rule->r_mapping = $8;
			if ($3) {
				if (strlcpy(rule->r_tag, $3, sizeof rule->r_tag)
				    >= sizeof rule->r_tag) {
					yyerror("tag name too long: %s", $3);
					free($3);
					YYERROR;
				}
				free($3);
			}
			TAILQ_INSERT_TAIL(conf->sc_rules, rule, r_entry);
			rule = NULL;
		}
		;
%%

struct keywords {
	const char	*k_name;
	int		 k_val;
};

int
yyerror(const char *fmt, ...)
{
	va_list		 ap;
	char		*nfmt;

	file->errors++;
	va_start(ap, fmt);
	if (asprintf(&nfmt, "%s:%d: %s", file->name, yylval.lineno, fmt) == -1)
		fatalx("yyerror asprintf");
	vlog(LOG_CRIT, nfmt, ap);
	va_end(ap);
	free(nfmt);
	return (0);
}

int
kw_cmp(const void *k, const void *e)
{
	return (strcmp(k, ((const struct keywords *)e)->k_name));
}

int
lookup(char *s)
{
	/* this has to be sorted always */
	static const struct keywords keywords[] = {
		{ "accept",		ACCEPT },
		{ "alias",		ALIAS },
		{ "any",		ANY },
		{ "as",			AS },
		{ "auth",		AUTH },
		{ "auth-optional",     	AUTH_OPTIONAL },
		{ "backup",		BACKUP },
		{ "bounce-warn",	BOUNCEWARN },
		{ "ca",			CA },
		{ "certificate",	CERTIFICATE },
		{ "compression",	COMPRESSION },
		{ "deliver",		DELIVER },
		{ "dh-params",		DHPARAMS },
		{ "domain",		DOMAIN },
		{ "encryption",		ENCRYPTION },
		{ "expire",		EXPIRE },
		{ "filter",		FILTER },
		{ "for",		FOR },
		{ "from",		FROM },
		{ "helo",		HELO },
		{ "hostname",		HOSTNAME },
		{ "include",		INCLUDE },
		{ "inet4",		INET4 },
		{ "inet6",		INET6 },
		{ "key",		KEY },
		{ "limit",		LIMIT },
		{ "listen",		LISTEN },
		{ "lmtp",		LMTP },
		{ "local",		LOCAL },
		{ "maildir",		MAILDIR },
		{ "mask-source",	MASK_SOURCE },
		{ "max-message-size",  	MAXMESSAGESIZE },
		{ "max-mta-deferred",  	MAXMTADEFERRED },
		{ "max-scheduler-inflight",  	MAXSCHEDULERINFLIGHT },
		{ "mbox",		MBOX },
		{ "mda",		MDA },
		{ "mta",		MTA },
		{ "on",			ON },
		{ "pki",		PKI },
		{ "port",		PORT },
		{ "queue",		QUEUE },
		{ "reject",		REJECT },
		{ "relay",		RELAY },
		{ "sender",    		SENDER },
		{ "smtps",		SMTPS },
		{ "source",		SOURCE },
		{ "ssl",		SSL },
		{ "table",		TABLE },
		{ "tag",		TAG },
		{ "tagged",		TAGGED },
		{ "tls",		TLS },
		{ "tls-require",       	TLS_REQUIRE },
		{ "to",			TO },
		{ "userbase",		USERBASE },
		{ "verify",		VERIFY },
		{ "via",		VIA },
		{ "virtual",		VIRTUAL },
	};
	const struct keywords	*p;

	p = bsearch(s, keywords, sizeof(keywords)/sizeof(keywords[0]),
	    sizeof(keywords[0]), kw_cmp);

	if (p)
		return (p->k_val);
	else
		return (STRING);
}

#define MAXPUSHBACK	128

char	*parsebuf;
int	 parseindex;
char	 pushback_buffer[MAXPUSHBACK];
int	 pushback_index = 0;

int
lgetc(int quotec)
{
	int		c, next;

	if (parsebuf) {
		/* Read character from the parsebuffer instead of input. */
		if (parseindex >= 0) {
			c = parsebuf[parseindex++];
			if (c != '\0')
				return (c);
			parsebuf = NULL;
		} else
			parseindex++;
	}

	if (pushback_index)
		return (pushback_buffer[--pushback_index]);

	if (quotec) {
		if ((c = getc(file->stream)) == EOF) {
			yyerror("reached end of file while parsing "
			    "quoted string");
			if (file == topfile || popfile() == EOF)
				return (EOF);
			return (quotec);
		}
		return (c);
	}

	while ((c = getc(file->stream)) == '\\') {
		next = getc(file->stream);
		if (next != '\n') {
			c = next;
			break;
		}
		yylval.lineno = file->lineno;
		file->lineno++;
	}

	while (c == EOF) {
		if (file == topfile || popfile() == EOF)
			return (EOF);
		c = getc(file->stream);
	}
	return (c);
}

int
lungetc(int c)
{
	if (c == EOF)
		return (EOF);
	if (parsebuf) {
		parseindex--;
		if (parseindex >= 0)
			return (c);
	}
	if (pushback_index < MAXPUSHBACK-1)
		return (pushback_buffer[pushback_index++] = c);
	else
		return (EOF);
}

int
findeol(void)
{
	int	c;

	parsebuf = NULL;
	pushback_index = 0;

	/* skip to either EOF or the first real EOL */
	while (1) {
		c = lgetc(0);
		if (c == '\n') {
			file->lineno++;
			break;
		}
		if (c == EOF)
			break;
	}
	return (ERROR);
}

int
yylex(void)
{
	char	 buf[8096];
	char	*p, *val;
	int	 quotec, next, c;
	int	 token;

top:
	p = buf;
	while ((c = lgetc(0)) == ' ' || c == '\t')
		; /* nothing */

	yylval.lineno = file->lineno;
	if (c == '#')
		while ((c = lgetc(0)) != '\n' && c != EOF)
			; /* nothing */
	if (c == '$' && parsebuf == NULL) {
		while (1) {
			if ((c = lgetc(0)) == EOF)
				return (0);

			if (p + 1 >= buf + sizeof(buf) - 1) {
				yyerror("string too long");
				return (findeol());
			}
			if (isalnum(c) || c == '_') {
				*p++ = (char)c;
				continue;
			}
			*p = '\0';
			lungetc(c);
			break;
		}
		val = symget(buf);
		if (val == NULL) {
			yyerror("macro '%s' not defined", buf);
			return (findeol());
		}
		parsebuf = val;
		parseindex = 0;
		goto top;
	}

	switch (c) {
	case '\'':
	case '"':
		quotec = c;
		while (1) {
			if ((c = lgetc(quotec)) == EOF)
				return (0);
			if (c == '\n') {
				file->lineno++;
				continue;
			} else if (c == '\\') {
				if ((next = lgetc(quotec)) == EOF)
					return (0);
				if (next == quotec || c == ' ' || c == '\t')
					c = next;
				else if (next == '\n') {
					file->lineno++;
					continue;
				} else
					lungetc(next);
			} else if (c == quotec) {
				*p = '\0';
				break;
			}
			if (p + 1 >= buf + sizeof(buf) - 1) {
				yyerror("string too long");
				return (findeol());
			}
			*p++ = (char)c;
		}
		yylval.v.string = strdup(buf);
		if (yylval.v.string == NULL)
			err(1, "yylex: strdup");
		return (STRING);
	}

#define allowed_to_end_number(x) \
	(isspace(x) || x == ')' || x ==',' || x == '/' || x == '}' || x == '=')

	if (c == '-' || isdigit(c)) {
		do {
			*p++ = c;
			if ((unsigned)(p-buf) >= sizeof(buf)) {
				yyerror("string too long");
				return (findeol());
			}
		} while ((c = lgetc(0)) != EOF && isdigit(c));
		lungetc(c);
		if (p == buf + 1 && buf[0] == '-')
			goto nodigits;
		if (c == EOF || allowed_to_end_number(c)) {
			const char *errstr = NULL;

			*p = '\0';
			yylval.v.number = strtonum(buf, LLONG_MIN,
			    LLONG_MAX, &errstr);
			if (errstr) {
				yyerror("\"%s\" invalid number: %s",
				    buf, errstr);
				return (findeol());
			}
			return (NUMBER);
		} else {
nodigits:
			while (p > buf + 1)
				lungetc(*--p);
			c = *--p;
			if (c == '-')
				return (c);
		}
	}

	if (c == '=') {
		if ((c = lgetc(0)) != EOF && c == '>')
			return (ARROW);
		lungetc(c);
		c = '=';
	}

#define allowed_in_string(x) \
	(isalnum(x) || (ispunct(x) && x != '(' && x != ')' && \
	x != '{' && x != '}' && x != '<' && x != '>' && \
	x != '!' && x != '=' && x != '#' && \
	x != ','))

	if (isalnum(c) || c == ':' || c == '_') {
		do {
			*p++ = c;
			if ((unsigned)(p-buf) >= sizeof(buf)) {
				yyerror("string too long");
				return (findeol());
			}
		} while ((c = lgetc(0)) != EOF && (allowed_in_string(c)));
		lungetc(c);
		*p = '\0';
		if ((token = lookup(buf)) == STRING)
			if ((yylval.v.string = strdup(buf)) == NULL)
				err(1, "yylex: strdup");
		return (token);
	}
	if (c == '\n') {
		yylval.lineno = file->lineno;
		file->lineno++;
	}
	if (c == EOF)
		return (0);
	return (c);
}

int
check_file_secrecy(int fd, const char *fname)
{
	struct stat	st;

	if (fstat(fd, &st)) {
		log_warn("warn: cannot stat %s", fname);
		return (-1);
	}
	if (st.st_uid != 0 && st.st_uid != getuid()) {
		log_warnx("warn: %s: owner not root or current user", fname);
		return (-1);
	}
	if (st.st_mode & (S_IRWXG | S_IRWXO)) {
		log_warnx("warn: %s: group/world readable/writeable", fname);
		return (-1);
	}
	return (0);
}

struct file *
pushfile(const char *name, int secret)
{
	struct file	*nfile;

	if ((nfile = calloc(1, sizeof(struct file))) == NULL) {
		log_warn("warn: malloc");
		return (NULL);
	}
	if ((nfile->name = strdup(name)) == NULL) {
		log_warn("warn: malloc");
		free(nfile);
		return (NULL);
	}
	if ((nfile->stream = fopen(nfile->name, "r")) == NULL) {
		log_warn("warn: %s", nfile->name);
		free(nfile->name);
		free(nfile);
		return (NULL);
	} else if (secret &&
	    check_file_secrecy(fileno(nfile->stream), nfile->name)) {
		fclose(nfile->stream);
		free(nfile->name);
		free(nfile);
		return (NULL);
	}
	nfile->lineno = 1;
	TAILQ_INSERT_TAIL(&files, nfile, entry);
	return (nfile);
}

int
popfile(void)
{
	struct file	*prev;

	if ((prev = TAILQ_PREV(file, files, entry)) != NULL)
		prev->errors += file->errors;

	TAILQ_REMOVE(&files, file, entry);
	fclose(file->stream);
	free(file->name);
	free(file);
	file = prev;
	return (file ? 0 : EOF);
}

int
parse_config(struct smtpd *x_conf, const char *filename, int opts)
{
	struct sym     *sym, *next;
	struct table   *t;
	char		hostname[SMTPD_MAXHOSTNAMELEN];
	char		hostname_copy[SMTPD_MAXHOSTNAMELEN];

	if (! getmailname(hostname, sizeof hostname))
		return (-1);

	conf = x_conf;
	bzero(conf, sizeof(*conf));

	strlcpy(conf->sc_hostname, hostname, sizeof(conf->sc_hostname));

	conf->sc_maxsize = DEFAULT_MAX_BODY_SIZE;

	conf->sc_tables_dict = calloc(1, sizeof(*conf->sc_tables_dict));
	conf->sc_rules = calloc(1, sizeof(*conf->sc_rules));
	conf->sc_listeners = calloc(1, sizeof(*conf->sc_listeners));
	conf->sc_ssl_dict = calloc(1, sizeof(*conf->sc_ssl_dict));
	conf->sc_limits_dict = calloc(1, sizeof(*conf->sc_limits_dict));

	/* Report mails delayed for more than 4 hours */
	conf->sc_bounce_warn[0] = 3600 * 4;

	if (conf->sc_tables_dict == NULL	||
	    conf->sc_rules == NULL		||
	    conf->sc_listeners == NULL		||
	    conf->sc_ssl_dict == NULL		||
	    conf->sc_limits_dict == NULL) {
		log_warn("warn: cannot allocate memory");
		free(conf->sc_tables_dict);
		free(conf->sc_rules);
		free(conf->sc_listeners);
		free(conf->sc_ssl_dict);
		free(conf->sc_limits_dict);
		return (-1);
	}

	errors = 0;

	table = NULL;
	rule = NULL;

	dict_init(&conf->sc_filters);

	dict_init(conf->sc_ssl_dict);
	dict_init(conf->sc_tables_dict);

	dict_init(conf->sc_limits_dict);
	limits = xcalloc(1, sizeof(*limits), "mta_limits");
	limit_mta_set_defaults(limits);
	dict_xset(conf->sc_limits_dict, "default", limits);

	TAILQ_INIT(conf->sc_listeners);
	TAILQ_INIT(conf->sc_rules);

	conf->sc_qexpire = SMTPD_QUEUE_EXPIRY;
	conf->sc_opts = opts;

	conf->sc_mta_max_deferred = 100;
	conf->sc_scheduler_max_inflight = 5000;

	if ((file = pushfile(filename, 0)) == NULL) {
		purge_config(PURGE_EVERYTHING);
		return (-1);
	}
	topfile = file;

	/*
	 * declare special "localhost", "anyhost" and "localnames" tables
	 */
	set_localaddrs();

	t = table_create("static", "<localnames>", NULL, NULL);
	t->t_type = T_LIST;
	table_add(t, "localhost", NULL);
	table_add(t, hostname, NULL);

	/* can't truncate here */
	(void)strlcpy(hostname_copy, hostname, sizeof hostname_copy);

	hostname_copy[strcspn(hostname_copy, ".")] = '\0';
	if (strcmp(hostname, hostname_copy) != 0)
		table_add(t, hostname_copy, NULL);

	table_create("getpwnam", "<getpwnam>", NULL, NULL);

	/*
	 * parse configuration
	 */
	setservent(1);
	yyparse();
	errors = file->errors;
	popfile();
	endservent();

	/* Free macros and check which have not been used. */
	for (sym = TAILQ_FIRST(&symhead); sym != NULL; sym = next) {
		next = TAILQ_NEXT(sym, entry);
		if ((conf->sc_opts & SMTPD_OPT_VERBOSE) && !sym->used)
			fprintf(stderr, "warning: macro '%s' not "
			    "used\n", sym->nam);
		if (!sym->persist) {
			free(sym->nam);
			free(sym->val);
			TAILQ_REMOVE(&symhead, sym, entry);
			free(sym);
		}
	}

	if (TAILQ_EMPTY(conf->sc_rules)) {
		log_warnx("warn: no rules, nothing to do");
		errors++;
	}

	if (errors) {
		purge_config(PURGE_EVERYTHING);
		return (-1);
	}

	return (0);
}

int
symset(const char *nam, const char *val, int persist)
{
	struct sym	*sym;

	for (sym = TAILQ_FIRST(&symhead); sym && strcmp(nam, sym->nam);
	    sym = TAILQ_NEXT(sym, entry))
		;	/* nothing */

	if (sym != NULL) {
		if (sym->persist == 1)
			return (0);
		else {
			free(sym->nam);
			free(sym->val);
			TAILQ_REMOVE(&symhead, sym, entry);
			free(sym);
		}
	}
	if ((sym = calloc(1, sizeof(*sym))) == NULL)
		return (-1);

	sym->nam = strdup(nam);
	if (sym->nam == NULL) {
		free(sym);
		return (-1);
	}
	sym->val = strdup(val);
	if (sym->val == NULL) {
		free(sym->nam);
		free(sym);
		return (-1);
	}
	sym->used = 0;
	sym->persist = persist;
	TAILQ_INSERT_TAIL(&symhead, sym, entry);
	return (0);
}

int
cmdline_symset(char *s)
{
	char	*sym, *val;
	int	ret;
	size_t	len;

	if ((val = strrchr(s, '=')) == NULL)
		return (-1);

	len = strlen(s) - strlen(val) + 1;
	if ((sym = malloc(len)) == NULL)
		errx(1, "cmdline_symset: malloc");

	(void)strlcpy(sym, s, len);

	ret = symset(sym, val + 1, 1);
	free(sym);

	return (ret);
}

char *
symget(const char *nam)
{
	struct sym	*sym;

	TAILQ_FOREACH(sym, &symhead, entry)
		if (strcmp(nam, sym->nam) == 0) {
			sym->used = 1;
			return (sym->val);
		}
	return (NULL);
}

static void
config_listener(struct listener *h,  const char *name, const char *tag,
    const char *pki, in_port_t port, const char *authtable, uint16_t flags,
    const char *helo)
{
	h->fd = -1;
	h->port = port;
	h->flags = flags;

	if (helo == NULL)
		helo = conf->sc_hostname;

	h->ssl = NULL;
	h->ssl_cert_name[0] = '\0';

	if (authtable != NULL)
		(void)strlcpy(h->authtable, authtable, sizeof(h->authtable));
	if (pki != NULL)
		(void)strlcpy(h->ssl_cert_name, pki, sizeof(h->ssl_cert_name));
	if (tag != NULL)
		(void)strlcpy(h->tag, tag, sizeof(h->tag));

	(void)strlcpy(h->helo, helo, sizeof(h->helo));
}

struct listener *
host_v4(const char *s, in_port_t port)
{
	struct in_addr		 ina;
	struct sockaddr_in	*sain;
	struct listener		*h;

	bzero(&ina, sizeof(ina));
	if (inet_pton(AF_INET, s, &ina) != 1)
		return (NULL);

	h = xcalloc(1, sizeof(*h), "host_v4");
	sain = (struct sockaddr_in *)&h->ss;
#ifdef HAVE_STRUCT_SOCKADDR_IN_SIN_LEN
	sain->sin_len = sizeof(struct sockaddr_in);
#endif
	sain->sin_family = AF_INET;
	sain->sin_addr.s_addr = ina.s_addr;
	sain->sin_port = port;

	return (h);
}

struct listener *
host_v6(const char *s, in_port_t port)
{
	struct in6_addr		 ina6;
	struct sockaddr_in6	*sin6;
	struct listener		*h;

	bzero(&ina6, sizeof(ina6));
	if (inet_pton(AF_INET6, s, &ina6) != 1)
		return (NULL);

	h = xcalloc(1, sizeof(*h), "host_v6");
	sin6 = (struct sockaddr_in6 *)&h->ss;
#ifdef HAVE_STRUCT_SOCKADDR_IN6_SIN6_LEN
	sin6->sin6_len = sizeof(struct sockaddr_in6);
#endif
	sin6->sin6_family = AF_INET6;
	sin6->sin6_port = port;
	memcpy(&sin6->sin6_addr, &ina6, sizeof(ina6));

	return (h);
}

int
host_dns(const char *s, const char *tag, const char *pki,
    struct listenerlist *al, int max, in_port_t port, const char *authtable,
    uint16_t flags, const char *helo)
{
	struct addrinfo		 hints, *res0, *res;
	int			 error, cnt = 0;
	struct sockaddr_in	*sain;
	struct sockaddr_in6	*sin6;
	struct listener		*h;

	bzero(&hints, sizeof(hints));
	hints.ai_family = PF_UNSPEC;
	hints.ai_socktype = SOCK_DGRAM; /* DUMMY */
	error = getaddrinfo(s, NULL, &hints, &res0);
	if (error == EAI_AGAIN || error == EAI_NODATA || error == EAI_NONAME)
		return (0);
	if (error) {
		log_warnx("warn: host_dns: could not parse \"%s\": %s", s,
		    gai_strerror(error));
		return (-1);
	}

	for (res = res0; res && cnt < max; res = res->ai_next) {
		if (res->ai_family != AF_INET &&
		    res->ai_family != AF_INET6)
			continue;
		h = xcalloc(1, sizeof(*h), "host_dns");

		h->ss.ss_family = res->ai_family;
		if (res->ai_family == AF_INET) {
			sain = (struct sockaddr_in *)&h->ss;
#ifdef HAVE_STRUCT_SOCKADDR_IN_SIN_LEN
			sain->sin_len = sizeof(struct sockaddr_in);
#endif
			sain->sin_addr.s_addr = ((struct sockaddr_in *)
			    res->ai_addr)->sin_addr.s_addr;
			sain->sin_port = port;
		} else {
			sin6 = (struct sockaddr_in6 *)&h->ss;
#ifdef HAVE_STRUCT_SOCKADDR_IN6_SIN6_LEN
			sin6->sin6_len = sizeof(struct sockaddr_in6);
#endif
			memcpy(&sin6->sin6_addr, &((struct sockaddr_in6 *)
			    res->ai_addr)->sin6_addr, sizeof(struct in6_addr));
			sin6->sin6_port = port;
		}

		config_listener(h, s, tag, pki, port, authtable, flags, helo);

		TAILQ_INSERT_HEAD(al, h, entry);
		cnt++;
	}
	if (cnt == max && res) {
		log_warnx("warn: host_dns: %s resolves to more than %d hosts",
		    s, max);
	}
	freeaddrinfo(res0);
	return (cnt);
}

int
host(const char *s, const char *tag, const char *pki, struct listenerlist *al,
    int max, in_port_t port, const char *authtable, uint16_t flags,
    const char *helo)
{
	struct listener *h;

	port = htons(port);

	h = host_v4(s, port);

	/* IPv6 address? */
	if (h == NULL)
		h = host_v6(s, port);

	if (h != NULL) {
		config_listener(h, s, tag, pki, port, authtable, flags, helo);
		TAILQ_INSERT_HEAD(al, h, entry);
		return (1);
	}

	return (host_dns(s, tag, pki, al, max, port, authtable, flags, helo));
}

int
interface(const char *s, int family, const char *tag, const char *pki,
    struct listenerlist *al, int max, in_port_t port, const char *authtable,
    uint16_t flags, const char *helo)
{
	struct ifaddrs *ifap, *p;
	struct sockaddr_in	*sain;
	struct sockaddr_in6	*sin6;
	struct listener		*h;
	int ret = 0;

	port = htons(port);

	if (getifaddrs(&ifap) == -1)
		fatal("getifaddrs");

	for (p = ifap; p != NULL; p = p->ifa_next) {
		if (p->ifa_addr == NULL)
			continue;
		if (strcmp(p->ifa_name, s) != 0 &&
		    ! is_if_in_group(p->ifa_name, s))
			continue;
		if (family != AF_UNSPEC && family != p->ifa_addr->sa_family)
			continue;

		h = xcalloc(1, sizeof(*h), "interface");

		switch (p->ifa_addr->sa_family) {
		case AF_INET:
			sain = (struct sockaddr_in *)&h->ss;
			*sain = *(struct sockaddr_in *)p->ifa_addr;
#ifdef HAVE_STRUCT_SOCKADDR_IN_SIN_LEN
			sain->sin_len = sizeof(struct sockaddr_in);
#endif
			sain->sin_port = port;
			break;

		case AF_INET6:
			sin6 = (struct sockaddr_in6 *)&h->ss;
			*sin6 = *(struct sockaddr_in6 *)p->ifa_addr;
#ifdef HAVE_STRUCT_SOCKADDR_IN6_SIN6_LEN
			sin6->sin6_len = sizeof(struct sockaddr_in6);
#endif
			sin6->sin6_port = port;
			break;

		default:
			free(h);
			continue;
		}

		config_listener(h, s, tag, pki, port, authtable, flags, helo);
		ret = 1;
		TAILQ_INSERT_HEAD(al, h, entry);
	}

	freeifaddrs(ifap);

	return ret;
}

void
set_localaddrs(void)
{
	struct ifaddrs *ifap, *p;
	struct sockaddr_storage ss;
	struct sockaddr_in	*sain;
	struct sockaddr_in6	*sin6;
	struct table		*t;

	t = table_create("static", "<anyhost>", NULL, NULL);
	table_add(t, "local", NULL);
	table_add(t, "0.0.0.0/0", NULL);
	table_add(t, "::/0", NULL);

#ifdef VALGRIND
	bzero(&ss, sizeof(ss));
#endif

	if (getifaddrs(&ifap) == -1)
		fatal("getifaddrs");

	t = table_create("static", "<localhost>", NULL, NULL);
	table_add(t, "local", NULL);

	for (p = ifap; p != NULL; p = p->ifa_next) {
		if (p->ifa_addr == NULL)
			continue;
		switch (p->ifa_addr->sa_family) {
		case AF_INET:
			sain = (struct sockaddr_in *)&ss;
			*sain = *(struct sockaddr_in *)p->ifa_addr;
#ifdef HAVE_STRUCT_SOCKADDR_IN_SIN_LEN
			sain->sin_len = sizeof(struct sockaddr_in);
#endif
			table_add(t, ss_to_text(&ss), NULL);
			break;

		case AF_INET6:
			sin6 = (struct sockaddr_in6 *)&ss;
			*sin6 = *(struct sockaddr_in6 *)p->ifa_addr;
#ifdef HAVE_STRUCT_SOCKADDR_IN6_SIN6_LEN
			sin6->sin6_len = sizeof(struct sockaddr_in6);
#endif
			table_add(t, ss_to_text(&ss), NULL);
			break;
		}
	}

	freeifaddrs(ifap);
}

int
delaytonum(char *str)
{
	unsigned int     factor;
	size_t           len;
	const char      *errstr = NULL;
	int              delay;
  	
	/* we need at least 1 digit and 1 unit */
	len = strlen(str);
	if (len < 2)
		goto bad;
	
	switch(str[len - 1]) {
		
	case 's':
		factor = 1;
		break;
		
	case 'm':
		factor = 60;
		break;
		
	case 'h':
		factor = 60 * 60;
		break;
		
	case 'd':
		factor = 24 * 60 * 60;
		break;
		
	default:
		goto bad;
	}
  	
	str[len - 1] = '\0';
	delay = strtonum(str, 1, INT_MAX / factor, &errstr);
	if (errstr)
		goto bad;
	
	return (delay * factor);
  	
bad:
	return (-1);
}

int
is_if_in_group(const char *ifname, const char *groupname)
{
#ifdef HAVE_STRUCT_IFGROUPREQ
        unsigned int		 len;
        struct ifgroupreq        ifgr;
        struct ifg_req          *ifg;
	int			 s;
	int			 ret = 0;

	if ((s = socket(AF_INET, SOCK_DGRAM, 0)) < 0)
		err(1, "socket");

        memset(&ifgr, 0, sizeof(ifgr));
        strlcpy(ifgr.ifgr_name, ifname, IFNAMSIZ);
        if (ioctl(s, SIOCGIFGROUP, (caddr_t)&ifgr) == -1) {
                if (errno == EINVAL || errno == ENOTTY)
			goto end;
		err(1, "SIOCGIFGROUP");
        }

        len = ifgr.ifgr_len;
        ifgr.ifgr_groups =
            (struct ifg_req *)xcalloc(len/sizeof(struct ifg_req),
		sizeof(struct ifg_req), "is_if_in_group");
        if (ioctl(s, SIOCGIFGROUP, (caddr_t)&ifgr) == -1)
                err(1, "SIOCGIFGROUP");
	
        ifg = ifgr.ifgr_groups;
        for (; ifg && len >= sizeof(struct ifg_req); ifg++) {
                len -= sizeof(struct ifg_req);
		if (strcmp(ifg->ifgrq_group, groupname) == 0) {
			ret = 1;
			break;
		}
        }
        free(ifgr.ifgr_groups);

end:
	close(s);
	return ret;
#else
	return (0);
#endif
}
