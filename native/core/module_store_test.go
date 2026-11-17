package core

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
)

func TestModuleStoreMergesOfficialAndCustom(t *testing.T) {
	example := filepath.Join("..", "module_example", "jsexample")
	manifest, err := os.ReadFile(filepath.Join(example, moduleManifest))
	if err != nil {
		t.Fatal(err)
	}
	code, err := os.ReadFile(filepath.Join(example, moduleEntry))
	if err != nil {
		t.Fatal(err)
	}
	customManifest := []byte(strings.Replace(string(manifest), `"id": "jsexample"`, `"id": "custom"`, 1))
	if string(customManifest) == string(manifest) {
		t.Fatal("example manifest id format changed")
	}
	files := map[string]map[string][]byte{
		"owner/official": {moduleManifest: manifest, moduleEntry: code},
		"owner/custom":   {moduleManifest: customManifest, moduleEntry: code},
	}
	hashes := map[string]map[string]string{}
	for repo, repoFiles := range files {
		hashes[repo] = map[string]string{}
		for name, data := range repoFiles {
			sum := sha256.Sum256(data)
			hashes[repo][name] = hex.EncodeToString(sum[:])
		}
	}
	entry := func(id, repo string) moduleIndexEntry {
		return moduleIndexEntry{
			ID: id, Name: id, Version: "1.0.0", API: moduleAPIVersion,
			Repo: repo, Tag: "v1.0.0", SHA256: hashes[repo],
		}
	}
	official, _ := json.Marshal(map[string]any{"format": moduleIndexFormat, "modules": []moduleIndexEntry{
		entry("jsexample", "owner/official"),
	}})
	custom, _ := json.Marshal(map[string]any{"format": moduleIndexFormat, "modules": []moduleIndexEntry{
		entry("custom", "owner/custom"),
	}})
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch {
		case request.URL.Path == "/official/index.json":
			_, _ = writer.Write(official)
		case request.URL.Path == "/custom/index.json":
			_, _ = writer.Write(custom)
		case strings.HasPrefix(request.URL.Path, "/files/owner/official/v1.0.0/"):
			_, _ = writer.Write(files["owner/official"][filepath.Base(request.URL.Path)])
		case strings.HasPrefix(request.URL.Path, "/files/owner/custom/v1.0.0/"):
			_, _ = writer.Write(files["owner/custom"][filepath.Base(request.URL.Path)])
		default:
			http.NotFound(writer, request)
		}
	}))
	t.Cleanup(server.Close)

	addresses, extra, patterns := moduleIndexAddresses, moduleExtraIndexAddresses, moduleFileAddresses
	bundled := bundledModules
	moduleIndexAddresses = []string{server.URL + "/official/index.json"}
	moduleExtraIndexAddresses = []string{server.URL + "/custom/index.json"}
	moduleFileAddresses = []string{server.URL + "/files/%s/%s/%s"}
	bundledModules = fstest.MapFS{}
	t.Cleanup(func() {
		moduleIndexAddresses, moduleExtraIndexAddresses, moduleFileAddresses = addresses, extra, patterns
		bundledModules = bundled
	})

	engine := &nativeEngine{downloader: &Downloader{cfg: Config{dataDir: t.TempDir()}, client: server.Client()}, cacheDirectory: t.TempDir()}
	ctx := context.Background()
	store, err := engine.moduleStore(ctx)
	if err != nil {
		t.Fatal(err)
	}
	items, _ := store["items"].([]moduleIndexEntry)
	if len(items) != 2 {
		t.Fatalf("items = %+v", items)
	}
	stores := map[string]string{}
	for _, item := range items {
		stores[item.ID] = item.Store
	}
	if stores["jsexample"] != moduleStoreOfficial || stores["custom"] != moduleStoreCustom {
		t.Fatalf("stores = %+v", stores)
	}
	if info, err := engine.prepareModule(ctx, "", "", moduleStoreCustom, "custom", false); err != nil || info.ID != "custom" || info.Token == "" {
		t.Fatalf("custom prepare = %+v, %v", info, err)
	}
	if info, err := engine.prepareModule(ctx, "", "", moduleStoreOfficial, "jsexample", false); err != nil || info.ID != "jsexample" {
		t.Fatalf("official prepare = %+v, %v", info, err)
	}
}
