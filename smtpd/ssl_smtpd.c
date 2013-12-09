/*	$OpenBSD$	*/

/*
 * Copyright (c) 2008 Pierre-Yves Ritschard <pyr@openbsd.org>
 * Copyright (c) 2008 Reyk Floeter <reyk@openbsd.org>
 * Copyright (c) 2012 Gilles Chehade <gilles@poolp.org>
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

#include <sys/types.h>
#include <sys/queue.h>
#include <sys/tree.h>
#include <sys/socket.h>
#include <sys/stat.h>

#include <ctype.h>
#include <event.h>
#include <fcntl.h>
#include <imsg.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <openssl/ssl.h>
#include <openssl/engine.h>
#include <openssl/err.h>

#include "smtpd.h"
#include "log.h"
#include "ssl.h"


void *
ssl_mta_init(char *cert, off_t cert_len, char *key, off_t key_len)
{
	SSL_CTX	*ctx = NULL;
	SSL	*ssl = NULL;

	ctx = ssl_ctx_create();

	if (cert != NULL && key != NULL) {
		if (!ssl_ctx_use_certificate_chain(ctx, cert, cert_len)) 
			goto err;
		else if (!ssl_ctx_use_private_key(ctx, key, key_len))
			goto err;
		else if (!SSL_CTX_check_private_key(ctx))
			goto err;
	}

	if ((ssl = SSL_new(ctx)) == NULL)
		goto err;
	if (!SSL_set_ssl_method(ssl, SSLv23_client_method()))
		goto err;

	SSL_CTX_free(ctx);
	return (void *)(ssl);

err:
	if (ssl != NULL)
		SSL_free(ssl);
	if (ctx != NULL)
		SSL_CTX_free(ctx);
	ssl_error("ssl_mta_init");
	return (NULL);
}

/* dummy_verify */
static int
dummy_verify(int ok, X509_STORE_CTX *store)
{
	/*
	 * We *want* SMTP to request an optional client certificate, however we don't want the
	 * verification to take place in the SMTP process. This dummy verify will allow us to
	 * asynchronously verify in the lookup process.
	 */
	return 1;
}

static int
servername_cb(SSL *s, int *ad, void *arg)
{
	const char	*sn;

	sn = SSL_get_servername(s, TLSEXT_NAMETYPE_host_name);
	if (sn == NULL)
		return SSL_TLSEXT_ERR_NOACK;
	return SSL_TLSEXT_ERR_OK;
}

void *
ssl_smtp_init(void *ssl_ctx, char *cert, off_t cert_len, char *key, off_t key_len)
{
	SSL	*ssl = NULL;

	log_debug("debug: session_start_ssl: switching to SSL");
	if (!ssl_ctx_use_certificate_chain(ssl_ctx, cert, cert_len))
		goto err;
	else if (!ssl_ctx_use_private_key(ssl_ctx, key, key_len))
		goto err;
	else if (!SSL_CTX_check_private_key(ssl_ctx))
		goto err;

	SSL_CTX_set_verify(ssl_ctx, SSL_VERIFY_PEER, dummy_verify);
	SSL_CTX_set_tlsext_servername_callback(ssl_ctx, servername_cb);

	if ((ssl = SSL_new(ssl_ctx)) == NULL)
		goto err;
	if (!SSL_set_ssl_method(ssl, SSLv23_server_method()))
		goto err;

	return (void *)(ssl);

err:
	if (ssl != NULL)
		SSL_free(ssl);
	ssl_error("ssl_smtp_init");
	return (NULL);
}
