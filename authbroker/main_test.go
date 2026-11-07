package main

import (
	"github.com/rclone/rclone/backend/onedrive"
	"github.com/rclone/rclone/fs/config/configstruct"
	"testing"
)

func TestReadOnlyDefaultsAndMemoryRotation(t *testing.T) {
	m := memoryConfig("old-token", "test-drive")
	var options onedrive.Options
	if err := configstruct.Set(m, &options); err != nil {
		t.Fatal(err)
	}
	if options.AccessScopes.String() != "Files.Read offline_access" {
		t.Fatal("unexpected scopes", options.AccessScopes)
	}
	if options.DriveID != "test-drive" || options.DriveType != "personal" {
		t.Fatal("invalid drive binding")
	}
	m.Set("token", "rotated-token")
	if got, _ := m.Get("token"); got != "rotated-token" {
		t.Fatal("rotation was not retained in memory")
	}
}
