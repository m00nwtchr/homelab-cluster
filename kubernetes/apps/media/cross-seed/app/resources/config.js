function fetchIndexers(baseUrl, apiKey, tag) {
	const buffer = require("child_process").execSync(
		`curl -fsSL "${baseUrl}/api/v1/tag/detail?apikey=${apiKey}"`,
	);
	const response = JSON.parse(buffer.toString("utf8"));
	const indexerIds =
		response.filter((t) => t.label === tag)[0]?.indexerIds ?? [];
	const indexers = indexerIds.map(
		(i) => `${baseUrl}/${i}/api?apikey=${apiKey}`,
	);
	console.log(`Loaded ${indexers.length} indexers from Prowlarr`);
	return indexers;
}

module.exports = {
	action: "inject",
	apiKey: process.env.CROSS_SEED_API_KEY,
	linkCategory: "cross-seed",
	linkDirs: ["/downloads/complete/cross-seed"],
	linkType: "hardlink",
	// dataDirs: ["/mnt/media/movies", "/mnt/media/tv"],
	// maxDataDepth: 3,
	seasonFromEpisodes: 0.5,
	matchMode: "partial",
	ignoreNonRelevantFilesToResume: true,
	radarr: [
		`http://radarr.media.svc.cluster.local/?apikey=${process.env.RADARR_API_KEY}`,
	],
	skipRecheck: true,
	sonarr: [
		`http://sonarr.media.svc.cluster.local/?apikey=${process.env.SONARR_API_KEY}`,
	],
	torrentClients: [`qbittorrent:http://qbittorrent.media.svc.cluster.local`],
	torznab: fetchIndexers(
		"http://prowlarr.media.svc.cluster.local",
		process.env.PROWLARR_API_KEY,
		"cross-seed",
	),
	useClientTorrents: true,
};
