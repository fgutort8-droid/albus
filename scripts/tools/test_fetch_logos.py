"""Offline transport checks; never download catalog content."""
import io
import socket
import unittest
from unittest.mock import Mock, patch
import fetch_logos as fetch

PUBLIC = (socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, '', ('93.184.216.34', 443))
PRIVATE = (socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, '', ('127.0.0.1', 443))

class Response(io.BytesIO):
    status = 200
    def geturl(self): return 'https://logos.example/icon.png'
    def getheader(self, name): return None

class FetchBoundaryTests(unittest.TestCase):
    def run_get(self, url, addresses=None, responses=None, limit=100):
        connection = Mock()
        connection.getresponse.side_effect = responses or [Response(b'image')]
        with patch.object(fetch.urllib.request, 'urlopen', return_value=Response(b'image')), \
             patch.object(socket, 'getaddrinfo', return_value=addresses or [PUBLIC]) as resolve, \
             patch.object(fetch, '_PublicHTTPSConnection', return_value=connection, create=True) as transport:
            result = fetch.get(url, limit)
        return result, resolve, transport, connection

    def test_non_https_and_credentials_never_open(self):
        for url in ['file:///tmp/icon.png', 'http://logos.example/icon', 'ftp://logos.example/icon',
                    'https://user:password@logos.example/icon', 'https://logos.example/\nicon']:
            with self.subTest(url=url):
                result, resolve, transport, _ = self.run_get(url)
                self.assertIsNone(result)
                resolve.assert_not_called(); transport.assert_not_called()

    def test_private_and_mixed_dns_never_open(self):
        for addresses in [[PRIVATE], [PUBLIC, PRIVATE]]:
            result, _, transport, _ = self.run_get('https://logos.example/icon', addresses)
            self.assertIsNone(result); transport.assert_not_called()

    def test_ipv6_nonpublic_never_open(self):
        for ip in ['::1', 'fc00::1', 'fe80::1', '::ffff:127.0.0.1', 'ff02::1']:
            with self.subTest(ip=ip):
                result, _, transport, _ = self.run_get('https://logos.example/icon',
                    [(socket.AF_INET6, socket.SOCK_STREAM, socket.IPPROTO_TCP, '', (ip,443,0,0))])
                self.assertIsNone(result); transport.assert_not_called()

    def test_public_https_keeps_bytes(self):
        result, _, _, connection = self.run_get('https://logos.example/icon.png')
        self.assertEqual(result, (b'image', 'https://logos.example/icon.png'))
        connection.close.assert_called_once()

    def test_redirect_rechecks_destination(self):
        response = Response(b''); response.status=302
        response.getheader=lambda _: 'https://127.0.0.1/icon'
        connection=Mock(); connection.getresponse.return_value=response
        with patch.object(fetch.urllib.request, 'urlopen', return_value=Response(b'image')), \
             patch.object(socket, 'getaddrinfo', side_effect=[[PUBLIC],[PRIVATE]]), \
             patch.object(fetch, '_PublicHTTPSConnection', return_value=connection, create=True) as transport:
            self.assertIsNone(fetch.get('https://logos.example/icon'))
            self.assertEqual(transport.call_count, 1)

    def test_redirect_limit_and_body_limit(self):
        response=Response(b''); response.status=302
        response.getheader=lambda _: '/loop'
        result, _, transport, _=self.run_get('https://logos.example/icon', responses=[response]*8)
        self.assertIsNone(result); self.assertLessEqual(transport.call_count,6)
        result, _, _, _=self.run_get('https://logos.example/icon',responses=[Response(b'123456')],limit=5)
        self.assertEqual(result, (b'12345', 'https://logos.example/icon'))

class SocketBindingTests(unittest.TestCase):
    def test_large_homepage_keeps_declared_icon_from_bounded_prefix(self):
        body=b'<link rel="apple-touch-icon" href="https://cdn.example/declared.png">'+b' '*400000
        connection=Mock();connection.getresponse.return_value=Response(body)
        with patch.object(socket,'getaddrinfo',return_value=[PUBLIC]), patch.object(fetch,'_PublicHTTPSConnection',return_value=connection):
            self.assertEqual(fetch.candidates('logos.example')[0],'https://cdn.example/declared.png')

    def test_unavailable_family_falls_back_to_approved_address(self):
        raw,context=Mock(),Mock()
        ipv6=(socket.AF_INET6,socket.SOCK_STREAM,socket.IPPROTO_TCP,'',('2606:4700:4700::1111',443,0,0))
        with patch.object(fetch.ssl,'create_default_context',return_value=context), \
             patch.object(socket,'socket',side_effect=[OSError('Unsupported address family'),raw]) as sockets:
            connection=fetch._PublicHTTPSConnection('logos.example',443,[ipv6,PUBLIC])
            connection.connect()
            self.assertEqual(sockets.call_count,2)
            raw.connect.assert_called_once_with(PUBLIC[4])
            connection.close()

    def test_checked_address_is_dialed_without_second_dns_lookup(self):
        raw, tls, context = Mock(), Mock(), Mock()
        context.wrap_socket.return_value=tls
        with patch.object(fetch.ssl, 'create_default_context', return_value=context), \
             patch.object(socket, 'socket', return_value=raw), \
             patch.object(socket, 'getaddrinfo', side_effect=AssertionError('Unexpected second lookup')):
            connection=fetch._PublicHTTPSConnection('logos.example',443,[PUBLIC])
            connection.connect()
            raw.connect.assert_called_once_with(PUBLIC[4])
            context.wrap_socket.assert_called_once_with(raw, server_hostname='logos.example')
            self.assertIs(connection.sock,tls)
            connection.close()
            tls.close.assert_called_once()

    def test_tls_failure_closes_raw_socket(self):
        raw, context=Mock(),Mock()
        context.wrap_socket.side_effect=fetch.ssl.SSLError('synthetic certificate rejection')
        with patch.object(fetch.ssl,'create_default_context',return_value=context), patch.object(socket,'socket',return_value=raw):
            connection=fetch._PublicHTTPSConnection('logos.example',443,[PUBLIC])
            with self.assertRaises(OSError): connection.connect()
            raw.close.assert_called_once()

    def test_public_cdn_redirect_retains_final_url_and_closes_each_hop(self):
        redirect=Response(b''); redirect.status=302
        redirect.getheader=lambda _: 'https://cdn.example/image.png?size=128'
        first,second=Mock(),Mock()
        first.getresponse.return_value=redirect;second.getresponse.return_value=Response(b'pixels')
        with patch.object(socket,'getaddrinfo',return_value=[PUBLIC]) as resolve, \
             patch.object(fetch,'_PublicHTTPSConnection',side_effect=[first,second]) as transport:
            self.assertEqual(fetch.get('https://logos.example/icon'),(b'pixels','https://cdn.example/image.png?size=128'))
            self.assertEqual([call.args[0] for call in resolve.call_args_list],['logos.example','cdn.example'])
            self.assertEqual(transport.call_args_list[1].args[0],'cdn.example')
            self.assertEqual(second.request.call_args.args[:2],('GET','/image.png?size=128'))
            first.close.assert_called_once();second.close.assert_called_once()

    def test_resolver_normalized_numeric_aliases_are_blocked(self):
        with patch.object(socket,'getaddrinfo',return_value=[PRIVATE]), \
             patch.object(fetch,'_PublicHTTPSConnection') as transport:
            for host in ['127.1','2130706433','0177.0.0.1','0x7f000001']:
                self.assertIsNone(fetch.get('https://'+host+'/icon'))
            transport.assert_not_called()

if __name__ == '__main__': unittest.main()
