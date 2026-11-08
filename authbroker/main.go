// PathSync uses rclone's supported OAuth implementation and public client.
// No user credentials or copied client secrets are embedded in this project.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/rclone/rclone/backend/onedrive"
	"github.com/rclone/rclone/cmd"
	_ "github.com/rclone/rclone/cmd/authorize"
	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/config/configmap"
	"os"
	"time"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "refresh-memory" {
		if err := refresh(); err != nil {
			fmt.Fprintln(os.Stderr, "OneDrive read-only token refresh failed")
			os.Exit(2)
		}
		return
	}
	// Only the explicitly invoked connect flow may start an OAuth web server.
	if len(os.Args) < 2 || os.Args[1] != "authorize" {
		os.Exit(2)
	}
	cmd.Main()
}
func memoryConfig(token, drive string) configmap.Mapper {
	in := configmap.Simple{"token": token, "drive_id": drive, "drive_type": "personal", "access_scopes": "Files.Read offline_access"}
	ri, _ := fs.Find("onedrive")
	m := fs.ConfigMap(ri.Prefix, ri.Options, "pathsync", in)
	m.ClearSetters()
	m.AddSetter(in)
	return m
}
func refresh() error {
	var input struct {
		Token   json.RawMessage `json:"token"`
		DriveID string          `json:"drive_id"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		return err
	}
	m := memoryConfig(string(input.Token), input.DriveID)
	ctx, cancel := context.WithTimeout(context.Background(), 35*time.Second)
	defer cancel()
	_, err := onedrive.NewFs(ctx, "pathsync", "", m)
	if err != nil {
		return err
	}
	raw, _ := m.Get("token")
	var token json.RawMessage = json.RawMessage(raw)
	return json.NewEncoder(os.Stdout).Encode(map[string]any{"token": token, "drive_id": input.DriveID})
}
