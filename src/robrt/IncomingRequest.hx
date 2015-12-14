package robrt;

import github.hook.Incoming;
import js.node.*;
import js.node.http.*;
import robrt.Variables;
import robrt.repository.RepoConfig;
import robrt.server.BuildDir;
import robrt.server.ServerConfig;

@:build(com.dongxiguo.continuation.Continuation.cpsByMeta("async"))
class IncomingRequest {
	public var buildId(default,null):String;
	var config:ServerConfig;
	var req:IncomingMessage;
	var res:ServerResponse;

	function new(config:ServerConfig, req:IncomingMessage, res:ServerResponse)
	{
		buildId = Crypto.pseudoRandomBytes(4).toString("hex");
		this.config = config;
		this.req = req;
		this.res = res;
	}

	static function parsePushRef(ref:String)
	{
		return ~/^refs\/(heads|tags)\//.replace(ref, "");
	}

	function getHook(web:Web, cb:js.Error->Incoming->Void)
	{
		try {
			var hook = Incoming.fromWeb(web);
			cb(null, hook);
		} catch (e:Dynamic) {
			cb(new js.Error(e), null);
		}
	}

	@async function execute()
	{
		var buf = new StringBuf();
		req.on("data", function (data:String) buf.add(data));

		@await req.on("end");
		var data = buf.toString();
		var web = {
			getClientHeader : function (name) return req.headers[name.toLowerCase()],
			getMethod : function () return req.method,
			getPostData : function () return data
		};

		var err, hook = @await getHook(web);
		if (err != null) {
			log('Error parsing request: $err');
			res.writeHead(400, { "Content-Type" : "text/plain" });
			res.end('ERROR: $err\n');
		}
		log('DELIVERY: ${hook.delivery}');

		var candidates = [];
		for (r in config.repositories) {
			if (r.hook_secret == null || hook.verify(r.hook_secret))
				candidates.push(r);
		}
		if (candidates.length == 0) {
			log("no signature matches");
			res.writeHead(404);
			res.end();
		}

		var delivery = hook.parse();
		log('repository: ${delivery.repository.full_name}');
		log('event: ${Type.enumConstructor(delivery.event)}');

		candidates = candidates.filter(function (r) return r.full_name == delivery.repository.full_name);
		if (candidates.length == 0) {
			log("no repository matches");
			res.writeHead(404);
			res.end();
			return;
		}
		log("repository matches: " + candidates.map(function (r) return r.full_name).join(", "));

		res.writeHead(202, { "Content-Type" : "text/plain" });
		res.end('Accepted, starting build id $buildId\n');

		switch (delivery.event) {
		case GitHubPing(e):  // done, NOOP
		case GitHubPush(e):
			var branch = parsePushRef(e.ref);
			var base = { branch : branch, commit : e.head_commit.id };

			if (e.deleted) {
				log('action: deleted $branch');
				log("TODO delete");
			} else {
				log('action: ${e.created?"created":"pushed"} $branch');
				for (repo in candidates) {
					var build = new PushBuild(this, repo, base);
					var status = @await build.run();
					if (status != 200) {
						log('build failed with $status');
						return;
					}
				}
			}
		case GitHubPullRequest(e):
			switch (e.action) {
			case Assigned, Unassigned, Labeled, Unlabeled, Closed: // NOOP
			case Opened, Synchronize, Reopened:
				log('base: ${e.pull_request.base.ref}');
				log('head: ${e.pull_request.head.ref}');
				var base = { branch : e.pull_request.base.ref, commit : e.pull_request.base.sha };
				var pr = { number : e.number, commit : e.pull_request.head.sha };
				for (repo in candidates) {
					var build = new PullRequestBuild(this, repo, base, pr);
					var status = @await build.run();
					if (status != 200) {
						log('build failed with $status');
						return;
					}
				}
			}
		}
	}

	public function log(msg:Dynamic, ?p:haxe.PosInfos)
	{
		Robrt.ctrace('[$buildId] $msg', p);
	}

	public static function handleRequest(config:ServerConfig, req:IncomingMessage, res:ServerResponse)
	{
		var r = new IncomingRequest(config, req, res);
		trace('${req.method} ${req.url} -> [${r.buildId}]');
		r.execute(function () {
			// TODO make the server shutdown wait for this
			r.log('Done');
		});
	}
}

