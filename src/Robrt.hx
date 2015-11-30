import github.hook.Incoming;
import js.node.*;
import js.node.http.*;
import robrt.Variables;
import robrt.repository.RepoConfig;
import robrt.server.BuildDir;
import robrt.server.ServerConfig;
import js.npm.dockerode.Docker;

/**
Robrt: a robot that listens to GitHub events and deploys stuff.

Usage:
  robrt.js listen <port>
  robrt.js -h | --help
  robrt.js --version

Environment variables:
  ROBRT_CONFIG      Alternate path to configuration file
**/
@:rtti
@:build(com.dongxiguo.continuation.Continuation.cpsByMeta("async"))
class Robrt {
	static inline var VERSION = "0.0.1-alpha.1";

	var buildId:String;
	var config:ServerConfig;
	var docker:Docker;

	static function ctrace(msg:Dynamic, ?p:haxe.PosInfos)
	{
		var lines = StringTools.rtrim(msg).split("\n");
		if (p.customParams != null)
			lines[lines.length - 1] += ': ' + p.customParams.join(',');
		var loc = '@${p.className}.${p.methodName}(${p.fileName}:${p.lineNumber})';
		if (lines.length > 1)
			lines.push(loc);
		else
			lines[lines.length - 1] += '  $loc';
		js.Node.console.log(lines.join("\n... "));
	}

	static function readServerConfig()
	{
		var path = Sys.getEnv(ServerVariables.ConfigPath);
		if (path == null)
			path = "/etc/robrt.json";
		if (!sys.FileSystem.exists(path) || sys.FileSystem.isDirectory(path))
			throw 'Invalid config path: $path';
		trace('Reading config file from $path');
		var data = haxe.Json.parse(sys.io.File.getContent(path));
		// TODO validate data
		return (data:ServerConfig);
	}

	static function parsePushRef(ref:String)
	{
		return ~/^refs\/(heads|tags)\//.replace(ref, "");
	}

	static function shEscape(s:String)
	{
		return "'" + s + "'";
	}

	function log(msg:Dynamic, ?p:haxe.PosInfos)
	{
		ctrace('[$buildId] $msg', p);
	}

	function getBuildDir(baseBuildDir, id):BuildDir
	{
		var base = Path.join(baseBuildDir, id);
		// probably there's nothing to remove
		try js.npm.Remove.removeSync(base, { ignoreMissing : true })
		catch (e:Dynamic) log('Warning: $e; kept going');
		return {
			base : base,
			repository : Path.join(base, "repository"),
			docker_build : Path.join(base, "docker_image.tar")
		}
	}

	// TODO handle submodules
	// TODO prevent git_terminal_prompt to /dev/tty (might be related to GIT_TERMINAL_PROMPT)
	@async function openRepo(fullName:String, dest:String, base:{ branch:String, commit:String }, ?pr:{ number:Int, commit:String }, ?token:String):Bool
	{
		var url = 'https://github.com/$fullName';
		// $token would sufice, but $token:$token prevents git from asking for a password on /dev/tty
		var authUrl = if (token == null) url else StringTools.replace(url, "https://", 'https://$token:$token@');

		// clone and checkout the specified commit
		// for homegeneity with `pr != null` reset the `base.branch` to `base.commit`
		// (this ensures that we're not building some more recent version of the branch by accident)
		var commands = [
			'git clone --quiet --branch ${shEscape(base.branch)} $authUrl $dest',
			'git -C $dest checkout --quiet --force ${base.commit}',
			'git -C $dest reset --quiet --hard ${base.commit}'
		];
		if (pr != null) {
			// fetch the pull request head and branch from the specified head commit
			// (this ensures that we're not building some more recent version of the PR by accident)
			commands = commands.concat([
				'git -C $dest fetch --quiet origin pull/${pr.number}/head',
				'git -C $dest branch --quiet pull/${pr.number}/head ${pr.commit}'
			]);
		}
		// cleanup the auth token
		if (token != null)
			commands.push('git -C $dest remote set-url origin $url');

		for (cmd in commands) {
			var err, stdout, stderr = @await ChildProcess.exec(cmd);
			if (err != null) {
				var msg = if (token == null) err.message else StringTools.replace(err.message, token, "******");
				log('ERR: $msg');
				return false;
			}
		}
		return true;
	}

	function readRepoConfig(repoDir:String):Null<RepoConfig>
	{
		// TODO make it async (requires fixed sync try/catch handling on haxe-continuation);
		// for this it is necessary to store context for Context.typeof or abandon that method
		// of choosing how to transform ETry expressions
		var confData = Fs.readFileSync(Path.join(repoDir, ".robrt.json"), "utf8");
		return haxe.Json.parse(confData);
	}

	function copyFile(src:String, dst:String, cb:js.Error->Void)
	{
		var src = Fs.createReadStream(src);
		var dst = Fs.createWriteStream(dst);
		src.on("error", cb);
		dst.on("error", cb);
		dst.on("finish", cb.bind(null));
		src.pipe(dst);
	}

	@async function writeFile(dest:String, file:robrt.repository.File)
	{
		var err;
		switch (file.type) {
		case InlineFile:
			err = @await Fs.writeFile(dest, file.data);
		case PathToFile:
			err = @await copyFile(file.data, dest);
		}
		return err;
	}

	@async function prepareDockerBuild(dest:String, opts:robrt.repository.PrepareOptions)
	{
		var tdest = dest + ".contents";
		var err = @await Fs.mkdir(tdest);
		if (err != null)
			return err;
		var err = @await writeFile(Path.join(tdest, "Dockerfile"), opts.dockerfile);
		if (err != null)
			return err;

		var err, stdout, stderr = @await ChildProcess.exec('tar --create --file $dest --directory $tdest .');
		if (err != null)
			return err;
		return null;
	}

	@async function prepare(buildDir:BuildDir)
	{
		var conf = try {
			readRepoConfig(buildDir.repository);
		} catch (e:Dynamic) {
			log('Could not read .robrt.json in the repository ($e)');
			return null;
		}

		var err = @await prepareDockerBuild(buildDir.docker_build, conf.prepare);
		if (err != null) {
			log(err);
			return null;
		}

		var err, ret = @await docker.buildImage(buildDir.docker_build, {});
		if (err != null) {
			log(err);
			return null;
		}
		return ret;
	}

	@async function execute(web:Web):Int
	{
		var hook:Incoming = try {
			Incoming.fromWeb(web);
		} catch (e:Dynamic) {
			// TODO try to return a more informative status, such as 400
			// (missing header, bad json), 405 (method not allowed), 415
			// (bad content-type) or 500 (other reasons)
			log('Failure to interpret: $e');
			return 500;
		}

		log('DELIVERY: ${hook.delivery}');

		var candidates = [];
		for (r in config.repositories) {
			if (r.hook_secret == null || hook.verify(r.hook_secret))
				candidates.push(r);
		}
		if (candidates.length == 0) {
			log("no signature matches");
			return 404;
		}

		var delivery = hook.parse();
		log('repository: ${delivery.repository.full_name}');
		log('event: ${Type.enumConstructor(delivery.event)}');

		candidates = candidates.filter(function (r) return r.full_name == delivery.repository.full_name);
		if (candidates.length == 0) {
			log("no repository matches");
			return 404;
		}
		log("repository matches: " + candidates.map(function (r) return r.full_name).join(", "));

		docker = new Docker();

		switch (delivery.event) {
		case GitHubPing(e):  // done, NOOP
		case GitHubPush(e):
			var branch = parsePushRef(e.ref);

			if (e.deleted) {
				log('action: deleted $branch');
				// TODO delete
				return 204;
			}

			log('action: ${e.created?"created":"pushed"} $branch');
			for (repo in candidates) {
				log("starting build");

				if (repo.build_options == null) {
					log("nothing to do, no 'build_options'");
					continue;
				} else if (repo.build_options.filter != null
						&& repo.build_options.filter.refs != null
						&& !Lambda.has(repo.build_options.filter.refs, branch)) {
					log("branch filtered out from building");
					continue;
				}

				var buildDir = getBuildDir(repo.build_options.directory, buildId);

				log("cloning");
				var b = { branch : branch, commit : e.head_commit.id };
				var ok = @await openRepo(repo.full_name, buildDir.repository, b, repo.oauth2_token);
				if (!ok)
					return 500;

				var image = @await prepare(buildDir);
				if (image == null)
					return 500;

				log("TODO build");
				return 501;

				if (repo.export_options == null) {
					log("nothing to export, no 'export_options'");
					continue;
				} else if (repo.export_options.filter != null
						&& repo.export_options.filter.refs != null
						&& !Lambda.has(repo.export_options.filter.refs, branch)) {
					log("branch filtered out from exporting");
					continue;
				}
				log("TODO export");
			}
		case GitHubPullRequest(e):
			switch (e.action) {
			case Assigned, Unassigned, Labeled, Unlabeled, Closed: // NOOP
			case Opened, Synchronize, Reopened:
				log('base: ${e.pull_request.base.ref}');
				log('head: ${e.pull_request.head.ref}');
				for (repo in candidates) {
					log("starting build");

					if (repo.build_options == null) {
						log("nothing to do, no 'build_options'");
						continue;
					} else if (repo.build_options.filter != null
							&& repo.build_options.filter.pull_requests != null
							&& !repo.build_options.filter.pull_requests) {
						log("building pull requests is disabled");
						continue;
					}

					var buildDir = getBuildDir(repo.build_options.directory, buildId);

					log("cloning");
					var b = { branch : e.pull_request.base.ref, commit : e.pull_request.base.sha };
					var p = { number : e.number, commit : e.pull_request.head.sha };
					var ok = @await openRepo(repo.full_name, buildDir.repository, b, p, repo.oauth2_token);
					if (!ok)
						return 500;

					log("TODO merge");
					return 501;

					log("TODO prepare");
					log("TODO build");

					if (repo.export_options == null) {
						log("nothing to export, no 'export_options'");
						continue;
					} else if (repo.export_options.filter != null
							&& repo.export_options.filter.pull_requests != null
							&& !repo.export_options.filter.pull_requests) {
						log("exporting of pull request build results is disabled");
						continue;
					}
					log("TODO export");
				}
			}
		}
		return 204;
	}

	function new(config)
	{
		buildId = Crypto.pseudoRandomBytes(4).toString("hex");
		this.config = config;
	}

	static function main()
	{
		haxe.Log.trace = function (msg, ?p) ctrace('  * $msg', p);
		var usage = haxe.rtti.Rtti.getRtti(Robrt).doc;
		var options = js.npm.Docopt.docopt(usage, { version : VERSION });

		trace("Starting");

		// safer to force a restart of the server before reloading new configs
		var config = readServerConfig();

		if (options["listen"]) {
			var port = Std.parseInt(options["<port>"]);
			if (port == null || port < 1 || port > 65355)
				throw 'Invalid port number ${options["<port>"]}';

			var server = Http.createServer(function (req, res) {
				var r = new Robrt(config);
				trace('${req.method} ${req.url} -> [${r.buildId}]');
				var buf = new StringBuf();
				req.on("data", function (data) buf.add(data));
				req.on("end", function () {
					var data = buf.toString();
					var web = {
						getClientHeader : function (name) return req.headers[name.toLowerCase()],
						getMethod : function () return req.method,
						getPostData : function () return data
					};
					r.execute(web, function (status) {
						r.log('Returnig $status (${Http.STATUS_CODES.get(Std.string(status))})');
						res.writeHead(status);
						res.end();
					});
				});
			});

			// handle exit from some signals
			function controledExit(signal:String)
			{
				var code = 128 + switch (signal) {
				case "SIGINT": 2;
				case "SIGTERM": 15;
				case "SIGUSR2": 12;  // nodemon uses this to restart
				case _: 0;  // ?
				}
				trace('Trying a controled shutdown after signal $signal');
				server.on("close", function () {
					trace('Succeded in shutting down the HTTP server; exiting now with code $code');
					js.Node.process.exit(code);
				});
				server.close();  // FIXME not really waiting for all responses to finish
			}
			js.Node.process.on("SIGINT", controledExit.bind("SIGINT"));
			js.Node.process.on("SIGTERM", controledExit.bind("SIGTERM"));
			js.Node.process.on("SIGUSR2", controledExit.bind("SIGUSR2"));

			server.listen(port);
			trace('Listening on port $port');
		} else {
			throw 'Should not have reached this point;\n$options';
		}
	}
}

