package client

import "time"

const ProtocolVersion = 1
const KernelRevision = "fb4ef139cbb4af67d142c72083fb735f56460e50"

type Problem struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Field   string `json:"field,omitempty"`
}

func (p *Problem) Error() string                { return p.Message }
func problem(code, message, field string) error { return &Problem{code, message, field} }

type Profile struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	Device      string    `json:"device"`
	Networks    []string  `json:"networks"`
	Groups      []string  `json:"groups"`
	Fingerprint string    `json:"fingerprint"`
	ExpiresAt   time.Time `json:"expiresAt"`
	ImportedAt  time.Time `json:"importedAt"`
	Version     string    `json:"version"`
	Digest      string    `json:"digest"`
}
type Candidate struct {
	Profile Profile `json:"profile"`
	Config  []byte  `json:"-"`
}
type Request struct {
	Version   int               `json:"version"`
	ID        string            `json:"id"`
	Method    string            `json:"method"`
	Path      string            `json:"path,omitempty"`
	ProfileID string            `json:"profileID,omitempty"`
	Name      string            `json:"name,omitempty"`
	Digest    string            `json:"digest,omitempty"`
	Files     map[string]string `json:"files,omitempty"`
	Address   string            `json:"address,omitempty"`
	Addresses []string          `json:"addresses,omitempty"`
}
type Response struct {
	Version int      `json:"version"`
	ID      string   `json:"id"`
	Result  any      `json:"result,omitempty"`
	Error   *Problem `json:"error,omitempty"`
}
type Peer struct {
	Name      string   `json:"name"`
	Addresses []string `json:"addresses"`
	Pending   bool     `json:"pending"`
}
type Status struct {
	StartedAt  *time.Time `json:"startedAt,omitempty"`
	ObservedAt time.Time  `json:"observedAt"`
	State      string     `json:"state"`
	ProfileID  string     `json:"profileID,omitempty"`
	Error      *Problem   `json:"error,omitempty"`
	Peers      []Peer     `json:"peers"`
}
type Event struct {
	Time time.Time `json:"time"`
	Code string    `json:"code"`
}
