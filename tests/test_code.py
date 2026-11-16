"""Local tests for the code in this repo (no AWS account needed).
Run:  pip install pytest moto boto3 pyyaml && pytest -q tests
"""
import json, os, sys, threading, urllib.request
from http.server import ThreadingHTTPServer

import boto3
import yaml
from moto import mock_aws

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "app"))


# ---------- the consumer: code is read from the template itself ----------
class Loader(yaml.SafeLoader):
    pass

Loader.add_multi_constructor("!", lambda loader, suffix, node: None)


def consumer_source():
    with open(os.path.join(ROOT, "infra", "messaging.yaml")) as f:
        tpl = yaml.load(f, Loader=Loader)
    return tpl["Resources"]["ConsumerFunction"]["Properties"]["Code"]["ZipFile"]


class Ctx:
    aws_request_id = "test"


def rec(mid, body):
    return {"messageId": mid, "body": body if isinstance(body, str) else json.dumps(body)}


@mock_aws
def test_consumer_is_idempotent_and_reports_failures():
    os.environ.update(AWS_DEFAULT_REGION="us-east-1", AWS_ACCESS_KEY_ID="x", AWS_SECRET_ACCESS_KEY="x")
    ddb = boto3.client("dynamodb")
    ddb.create_table(TableName="t", BillingMode="PAY_PER_REQUEST",
                     AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
                     KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}])
    os.environ["TABLE_NAME"] = "t"
    ns = {}
    exec(consumer_source(), ns)

    out = ns["handler"]({"Records": [rec("m1", {"orderId": "o-1", "total": 5})]}, Ctx())
    assert out == {"batchItemFailures": []}

    # same order again (new messageId): skipped, still one item, no failure
    out = ns["handler"]({"Records": [rec("m2", {"orderId": "o-1", "total": 5})]}, Ctx())
    assert out == {"batchItemFailures": []}
    assert ddb.scan(TableName="t")["Count"] == 1

    # poison message in the same batch as a good one: only the poison one is reported
    out = ns["handler"]({"Records": [rec("m3", {"poison": True}), rec("m4", {"orderId": "o-2"})]}, Ctx())
    assert out == {"batchItemFailures": [{"itemIdentifier": "m3"}]}
    assert ddb.scan(TableName="t")["Count"] == 2

    out = ns["handler"]({"Records": [rec("m5", "not json")]}, Ctx())
    assert out == {"batchItemFailures": [{"itemIdentifier": "m5"}]}


# ---------- the container app ----------
class FakeSNS:
    def __init__(self):
        self.published = []

    def publish(self, **kw):
        self.published.append(kw)


def call(method, url, body=None):
    req = urllib.request.Request(url, data=body, method=method)
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def test_app_endpoints():
    import app
    fake = FakeSNS()
    app.sns, app.TOPIC_ARN = fake, "arn:aws:sns:us-east-1:1:t"
    server = ThreadingHTTPServer(("127.0.0.1", 0), app.Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:%d" % server.server_address[1]

    assert call("GET", base + "/health") == (200, {"status": "ok"})
    assert call("GET", base + "/")[0] == 200
    assert call("POST", base + "/orders", b'{"orderId": "o-9", "total": 3}') == (202, {"published": "o-9"})
    assert json.loads(fake.published[0]["Message"])["orderId"] == "o-9"
    assert call("POST", base + "/orders", b'{"total": 3}')[0] == 400
    assert call("POST", base + "/orders", b"not json")[0] == 400
    assert call("POST", base + "/other", b"{}")[0] == 404
    app.sns = None
    assert call("POST", base + "/orders", b'{"orderId": "x"}')[0] == 503
    server.shutdown()
